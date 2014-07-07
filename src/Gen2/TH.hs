{-# LANGUAGE CPP, OverloadedStrings, LambdaCase, TupleSections, ScopedTypeVariables #-}

module Gen2.TH where

{-
  Template Haskell support through Node.js
-}

import           Compiler.Settings

import qualified Gen2.GHC.CoreToStg  as Gen2 -- version that does not generate StgLetNoEscape
import qualified Gen2.Generator      as Gen2
import qualified Gen2.Linker         as Gen2
import qualified Gen2.ClosureInfo    as Gen2
import qualified Gen2.Shim           as Gen2
import qualified Gen2.Object         as Gen2
import qualified Gen2.Cache          as Gen2

import           CoreUtils
import           CorePrep
import           BasicTypes
import           Name
import           Id
import           Outputable          hiding ((<>))
import           CoreSyn
import           SrcLoc
import           Module
import           DynFlags
import           TcRnMonad
import           HscTypes
import           GhcMonad            hiding (logWarnings)
import           TysWiredIn
import           Packages
import           Unique
import           Type
import           Maybes
import           UniqFM
import           SimplStg
import           Serialized
import           Annotations
import           Convert
import           RnEnv
import           FastString
import           RdrName

import           Control.Concurrent
import           Control.Concurrent.MVar
import           Control.Monad

import qualified Data.Map                       as M
import           Data.Text                      (Text)
import           Data.Binary
import           Data.Binary.Get
import           Data.Binary.Put
import           Data.ByteString                (ByteString)
import qualified Data.ByteString                as B
import qualified Data.ByteString.Base16         as B16
import qualified Data.ByteString.Lazy           as BL
import qualified Data.List                      as L
import           Data.Monoid
import qualified Data.Set                       as S
import qualified Data.Text                      as T
import qualified Data.Text.Encoding             as T
import qualified Data.Text.IO                   as T
import qualified Data.Text.Lazy.Encoding        as TL
import qualified Data.Text.Lazy                 as TL

import           GHC.Desugar

import qualified GHCJS.Prim.TH.Serialized       as TH
import qualified GHCJS.Prim.TH.Types            as TH

import qualified Language.Haskell.TH            as TH
import           Language.Haskell.TH.Syntax     (Quasi)
import qualified Language.Haskell.TH.Syntax     as TH

import           System.Process                 (runInteractiveProcess, ProcessHandle
                                                ,terminateProcess, waitForProcess)
import           System.FilePath
import           System.IO
import           System.IO.Error
import           System.Timeout

import           Unsafe.Coerce

#include "HsVersions.h"

-- | run some TH code, start a runner if necessary
runTh :: forall m. Quasi m
      => Bool
      -> GhcjsEnv
      -> HscEnv
      -> DynFlags
      -> Type       -- ^ type of the result
      -> ByteString -- ^ in-memory object of the compiled CoreExpr
      -> Text       -- ^ JavaScript symbol name that the expression is bound to
      -> m HValue
runTh is_io js_env hsc_env dflags ty code symb = do
  loc <- if is_io then return Nothing
                  else Just <$> TH.qLocation
  let m   = maybe "<global>" TH.loc_module loc
      sty = show ty
      toHv :: Show a => Get a -> ByteString -> m HValue
      toHv g b = let h = runGet g (BL.fromStrict b)
                 in  {- TH.qRunIO (print h) >> -} return (unsafeCoerce h)
      getAnnWrapper :: ByteString -> m HValue
      getAnnWrapper bs = return (unsafeCoerce $ AnnotationWrapper (B.unpack bs))
      convert
        | sty == "Language.Haskell.TH.Syntax.Q Language.Haskell.TH.Syntax.Exp"
            = Just (TH.THExp,  toHv (get :: Get TH.Exp))
        | sty == "Language.Haskell.TH.Syntax.Q [Language.Haskell.TH.Syntax.Dec]"
            = Just (TH.THDec,  toHv (get :: Get [TH.Dec]))
        | sty == "Language.Haskell.TH.Syntax.Q Language.Haskell.TH.Syntax.Pat"
            = Just (TH.THPat,  toHv (get :: Get TH.Pat))
        | sty == "Language.Haskell.TH.Syntax.Q Language.Haskell.TH.Lib.Type"
            = Just (TH.THType, toHv (get :: Get TH.Type))
        | sty == "GHC.Desugar.AnnotationWrapper"
            = Just (TH.THAnnWrapper, getAnnWrapper)
        | otherwise = Nothing
  case convert of
    Nothing -> error ("runTh: unexpected Template Haskell expression type: " ++ sty)
    Just (tht, getHv) -> do
      r <- getThRunner is_io dflags js_env hsc_env m
      base <- TH.qRunIO $ takeMVar (thrBase r)
      let settings = thSettings { gsUseBase = BaseState base }
      lr  <- TH.qRunIO $ linkTh settings [] dflags (hsc_HPT hsc_env) (Just code)
      ext <- TH.qRunIO $ mconcat <$> mapM B.readFile (Gen2.linkLibB lr ++ Gen2.linkLibA lr)
      let bs = ext <> BL.toStrict (Gen2.linkOut lr)
                   <> T.encodeUtf8 ("\nh$TH.loadedSymbol = " <> symb <> ";\n")
      hv <- requestRunner is_io r (TH.RunTH tht bs loc) >>= \case
              TH.RunTH' bsr -> getHv bsr
              _             -> error "runTh: unexpected response, expected RunTH' message"
      TH.qRunIO $ putMVar (thrBase r) (Gen2.linkBase lr)
      return hv

-- | instruct the runner to finish up
finishTh :: Quasi m => Bool -> GhcjsEnv -> String -> ThRunner -> m ()
finishTh is_io js_env m runner = do
  TH.qRunIO $ do
    takeMVar (thrBase runner)
    modifyMVar_ (thRunners js_env) (return . M.delete m)
  requestRunner is_io runner TH.FinishTH >>= \case
    TH.FinishTH' -> return ()
    _            -> error "finishTh: unexpected response, expected FinishTH' message"
  let ph = thrProcess runner
  TH.qRunIO $ maybe (void $ terminateProcess ph) (\_ -> return ()) =<< timeout 30000000 (waitForProcess ph)

thSettings :: GhcjsSettings
thSettings = GhcjsSettings False True False Nothing Nothing Nothing True True True Nothing NoBase

getThRunner :: Quasi m => Bool -> DynFlags -> GhcjsEnv -> HscEnv -> String -> m ThRunner
getThRunner is_io dflags js_env hsc_env m = do
  runners <- TH.qRunIO $ takeMVar (thRunners js_env)
  case M.lookup m runners of
    Just r  -> TH.qRunIO (putMVar (thRunners js_env) runners) >> return r
    Nothing -> do
      r <- TH.qRunIO $ do
        lr <- linkTh thSettings [] dflags (hsc_HPT hsc_env) Nothing
        fb <- BL.fromChunks <$> mapM (Gen2.tryReadShimFile dflags) (Gen2.linkLibB lr)
        fa <- BL.fromChunks <$> mapM (Gen2.tryReadShimFile dflags) (Gen2.linkLibA lr)
        let rts = TL.encodeUtf8 $ Gen2.rtsText' (Gen2.dfCgSettings dflags)
        node <- T.strip <$> T.readFile (topDir dflags </> "node")
        (inp,out,err,pid) <- runInteractiveProcess (T.unpack node) [topDir dflags </> "thrunner.js"] Nothing Nothing
        mv  <- newMVar (Gen2.linkBase lr)
        forkIO $ catchIOError (forever $ hGetChar out >>= putChar) (\_ -> return ())
        let r = ThRunner pid inp err mv
        sendToRunnerRaw r 0 (BL.toStrict $ fb <> rts <> fa <> Gen2.linkOut lr)
        return r
      when (not is_io) $ TH.qAddModFinalizer (TH.Q $ finishTh is_io js_env m r)
      TH.qRunIO $ putMVar (thRunners js_env) (M.insert m r runners)
      return r

sendToRunner :: ThRunner -> Int -> TH.Message -> IO ()
sendToRunner runner responseTo msg =
  sendToRunnerRaw runner responseTo (BL.toStrict . runPut . put $ msg)

sendToRunnerRaw :: ThRunner -> Int -> ByteString -> IO ()
sendToRunnerRaw runner responseTo bs = do
  let header = BL.toStrict . runPut $ do
        putWord32be (fromIntegral $ B.length bs)
        putWord32be (fromIntegral responseTo)
  B.hPut (thrHandleIn runner) (B16.encode $ header <> bs)
  hFlush (thrHandleIn runner)

requestRunner :: Quasi m => Bool -> ThRunner -> TH.Message -> m TH.Message
requestRunner is_io runner msg = TH.qRunIO (sendToRunner runner 0 msg) >> res
  where
    res = TH.qRunIO (readFromRunner runner) >>= \case
      (msg, 0) -> return msg
      (req, n) -> handleRunnerReq is_io runner req >>= TH.qRunIO . sendToRunner runner n >> res

readFromRunner :: ThRunner -> IO (TH.Message, Int)
readFromRunner runner = do
  let h = thrHandleErr runner
  (len, tgt) <- runGet ((,) <$> getWord32be <*> getWord32be) <$> BL.hGet h 8
  (,fromIntegral tgt) . runGet get <$> BL.hGet h (fromIntegral len)

handleRunnerReq :: Quasi m => Bool -> ThRunner -> TH.Message -> m TH.Message
handleRunnerReq is_io runner msg = case msg of
  TH.NewName n           -> TH.NewName'                       <$> TH.qNewName n
  TH.QException e        -> term                              >>  error e
  TH.QFail e             -> term                              >>  fail e
  TH.Report isErr msg    -> TH.qReport isErr msg              >>  pure TH.Report'
  TH.LookupName b n      -> TH.LookupName'                    <$> TH.qLookupName b n
  TH.Reify n             -> TH.Reify'                         <$> TH.qReify n
  TH.ReifyInstances n ts -> TH.ReifyInstances'                <$> TH.qReifyInstances n ts
  TH.ReifyRoles n        -> TH.ReifyRoles'                    <$> TH.qReifyRoles n
  TH.ReifyAnnotations _ | is_io -> error "qReifyAnnotations not supported in IO"
  TH.ReifyAnnotations nn -> TH.ReifyAnnotations' . map B.pack <$> unsafeReifyAnnotationsQ nn
  TH.ReifyModule m       -> TH.ReifyModule'                   <$> TH.qReifyModule m
  TH.AddDependentFile f  -> TH.qAddDependentFile f            >>  pure TH.AddDependentFile'
  TH.AddTopDecls decs    -> TH.qAddTopDecls decs              >>  pure TH.AddTopDecls'
  _                      -> term >> error "handleRunnerReq: unexpected request"
  where
    term = TH.qRunIO (terminateProcess $ thrProcess runner)

ghcjsCompileCoreExpr :: GhcjsEnv -> GhcjsSettings -> HscEnv -> SrcSpan -> CoreExpr -> IO HValue
ghcjsCompileCoreExpr js_env settings hsc_env srcspan ds_expr = do
  prep_expr <- corePrepExpr dflags hsc_env ds_expr
  n <- modifyMVar (thSplice js_env) (\n -> let n' = n+1 in pure (n',n'))
  let bs = [bind n prep_expr]
      cg = CgGuts (mod n) [] bs NoStubs [] (NoHpcInfo False) emptyModBreaks
  stg_pgm0      <- Gen2.coreToStg dflags (mod n) bs
  (stg_pgm1, _) <- stg2stg dflags (mod n) stg_pgm0
  let bs = Gen2.generate settings dflags (mod n) stg_pgm1
      r  = TH.Q (runTh isNonQ js_env hsc_env dflags ty bs (symb n))
  if isNonQ
     then TH.runQ r               -- run inside IO, limited functionality, no reification
     else return (unsafeCoerce r) -- full functionality (for splices)
  where
    isNonQ   = show ty == "GHC.Desugar.AnnotationWrapper"
    symb n   = "h$thrunnerZCThRunner" <> T.pack (show n) <> "zithExpr"
    ty       = expandTypeSynonyms (exprType ds_expr)
    thExpr n = mkVanillaGlobal (mkExternalName (mkRegSingleUnique (1+n)) (mod n) (mkVarOcc "thExpr") srcspan) ty
    bind n e = NonRec (thExpr n) e
    mod n    = mkModule pkg (mkModuleName $ "ThRunner" ++ show n)
    pkg      = stringToPackageId "thrunner"
    dflags   = hsc_dflags hsc_env

linkTh :: GhcjsSettings        -- settings (contains the base state)
       -> [FilePath]           -- extra js files
       -> DynFlags             -- dynamic flags
       -> HomePackageTable     -- what to link
       -> Maybe ByteString     -- current module or Nothing to get the initial code + rts
       -> IO Gen2.LinkResult
linkTh settings js_files dflags hpt code = do
  let home_mod_infos = eltsUFM hpt
      pidMap    = pkgIdMap (pkgState dflags)
      pkg_deps :: [PackageId]
      pkg_deps  = concatMap (map fst . dep_pkgs . mi_deps . hm_iface) home_mod_infos
      linkables = map (expectJust "link".hm_linkable) home_mod_infos
      getOfiles (LM _ _ us) = map nameOfObject (filter isObject us)
      -- fixme include filename here?
      th_obj    = maybe [] (\b -> [Left ("<Template Haskell>", b)]) code
      obj_files = th_obj ++ map Right (concatMap getOfiles linkables)
      packageLibPaths :: PackageId -> [FilePath]
      packageLibPaths pkg = maybe [] libraryDirs (lookupPackage pidMap pkg)
      dflags' = dflags { ways = WayDebug : ways dflags }
  -- link all packages that TH depends on, error if not configured
  (th_deps_pkgs, mk_th_deps) <- Gen2.thDeps dflags
  (rts_deps_pkgs, _) <- Gen2.rtsDeps dflags
  let addDep pkgs name
        | any (matchPackageName name) pkgs = pkgs
        | otherwise = lookupRequiredPackage dflags "to run Template Haskell" name : pkgs
      pkg_deps' = L.foldl' addDep pkg_deps (th_deps_pkgs ++ rts_deps_pkgs)
      th_deps   = mk_th_deps pkg_deps'
      th_deps'  = T.pack . show . L.nub . L.sort . map Gen2.funPackage . S.toList $ th_deps
      deps      = map (\pkg -> (pkg, packageLibPaths pkg)) pkg_deps'
      is_root   = const True
      link      = Gen2.link' dflags' settings "template haskell" [] deps obj_files js_files is_root th_deps
  if isJust code
     then link
     else Gen2.getCached dflags "template-haskell" th_deps' >>= \case
            Just c  -> return (runGet get $ BL.fromStrict c)
            Nothing -> do
              lr <- link
              Gen2.putCached dflags "template-haskell" th_deps'
                              [topDir dflags </> "ghcjs_boot.completed"]
                              (BL.toStrict . runPut . put $ lr)
              return lr

lookupRequiredPackage :: DynFlags -> String -> Text -> PackageId
lookupRequiredPackage dflags requiredFor pkgName
  | (x:_) <- matches = x
  | otherwise        = error ("Package `" ++ T.unpack pkgName ++ "' is required " ++ requiredFor ++ " " ++ show (map packageIdString pkgIds))
  where
    matches = reverse . L.sort $ filter (matchPackageName pkgName) pkgIds
    pkgIds = map packageConfigId . eltsUFM . pkgIdMap . pkgState $ dflags

matchPackageName :: Text -> PackageId -> Bool
matchPackageName namePrefix pkgid =
  let pt = T.pack (packageIdString pkgid)
  in  pt == namePrefix || (namePrefix <> "-") `T.isPrefixOf` (pt<>"-") -- fixme partial number matches are supported in linker

ghcjsGetValueSafely :: GhcjsSettings
                    -> HscEnv
                    -> Name
                    -> Type
                    -> IO (Maybe HValue)
ghcjsGetValueSafely settings hsc_env name t = do
  return Nothing -- fixme

-- for some reason this doesn't work, although it seems to do the same as the code below
-- myReifyAnnotations :: TH.Quasi m => TH.AnnLookup -> m [[Word8]]
-- myReifyAnnotations = TH.qReifyAnnotations

{- NOINLINE unsafeReifyAnnotationsQ #-}
unsafeReifyAnnotationsQ :: TH.AnnLookup -> m [[Word8]]
unsafeReifyAnnotationsQ lookup = unsafeCoerce (reifyAnnotationsTcM lookup)

reifyAnnotationsTcM :: TH.AnnLookup -> TcM [[Word8]]
reifyAnnotationsTcM th_name = do
  name <- lookupThAnnLookup th_name
  topEnv <- getTopEnv
  epsHptAnns <- liftIO $ prepareAnnotations topEnv Nothing
  tcg <- getGblEnv
  let selectedEpsHptAnns = findAnns deserializeWithData epsHptAnns name
      selectedTcgAnns = findAnns deserializeWithData (tcg_ann_env tcg) name
  return (selectedEpsHptAnns ++ selectedTcgAnns)

lookupThAnnLookup :: TH.AnnLookup -> TcM CoreAnnTarget
lookupThAnnLookup (TH.AnnLookupName th_nm) = fmap NamedTarget (lookupThName th_nm)
lookupThAnnLookup (TH.AnnLookupModule (TH.Module pn mn))
  = return $ ModuleTarget $
    mkModule (stringToPackageId $ TH.pkgString pn) (mkModuleName $ TH.modString mn)

lookupThName :: TH.Name -> TcM Name
lookupThName th_name = do
    mb_name <- lookupThName_maybe th_name
    case mb_name of
        Nothing   -> failWithTc (notInScope th_name)
        Just name -> return name

lookupThName_maybe :: TH.Name -> TcM (Maybe Name)
lookupThName_maybe th_name
  =  do { names <- mapMaybeM lookup (thRdrNameGuesses th_name)
          -- Pick the first that works
          -- E.g. reify (mkName "A") will pick the class A in preference to the data constructor A
        ; return (listToMaybe names) }
  where
    lookup rdr_name
        = do {  -- Repeat much of lookupOccRn, becase we want
                -- to report errors in a TH-relevant way
             ; rdr_env <- getLocalRdrEnv
             ; case lookupLocalRdrEnv rdr_env rdr_name of
                 Just name -> return (Just name)
                 Nothing   -> lookupGlobalOccRn_maybe rdr_name }

notInScope :: TH.Name -> SDoc
notInScope th_name = quotes (text (TH.pprint th_name)) <+>
                     ptext (sLit "is not in scope at a reify")
        -- Ugh! Rather an indirect way to display the name


