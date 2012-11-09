{-# LANGUAGE BangPatterns #-}
module Erb.Compute(computeTemplate, getTemplateFile, initTemplateDaemon) where

import Data.List
import Puppet.Interpreter.Types
import Puppet.Init
import SafeProcess
import System.IO
import qualified Data.List.Utils as DLU
import Control.Monad.Error
import Control.Concurrent
import System.Posix.Files
import Paths_language_puppet (getDataFileName)
import Erb.Parser
import Erb.Evaluate
import qualified Data.Map as Map
import Debug.Trace
import qualified Data.ByteString.Lazy.Char8 as BS
import qualified Data.ByteString.Builder as BB
import Data.Monoid
import qualified System.Log.Logger as LOG

type TemplateQuery = (Chan TemplateAnswer, String, String, Map.Map String GeneralValue)
type TemplateAnswer = Either String String

initTemplateDaemon :: Prefs -> IO (String -> String -> Map.Map String GeneralValue -> IO (Either String String))
initTemplateDaemon (Prefs _ modpath templatepath _ _ ps _ _) = do
    controlchan <- newChan
    replicateM_ ps (forkIO (templateDaemon modpath templatepath controlchan))
    return (templateQuery controlchan)

templateQuery :: Chan TemplateQuery -> String -> String -> Map.Map String GeneralValue -> IO (Either String String)
templateQuery qchan filename scope variables = do
    rchan <- newChan
    writeChan qchan (rchan, filename, scope, variables)
    readChan rchan

templateDaemon :: String -> String -> Chan TemplateQuery -> IO ()
templateDaemon modpath templatepath qchan = do
    (respchan, filename, scope, variables) <- readChan qchan
    let parts = DLU.split "/" filename
        searchpathes | length parts > 1 = [modpath ++ "/" ++ head parts ++ "/templates/" ++ (DLU.join "/" (tail parts)), templatepath ++ "/" ++ filename]
                     | otherwise        = [templatepath ++ "/" ++ filename]
    acceptablefiles <- filterM fileExist searchpathes
    if(null acceptablefiles)
        then writeChan respchan (Left $ "Can't find template file for " ++ filename ++ ", looked in " ++ show searchpathes)
        else computeTemplate (head acceptablefiles) scope variables >>= writeChan respchan
    templateDaemon modpath templatepath qchan

computeTemplate :: String -> String -> Map.Map String GeneralValue -> IO TemplateAnswer
computeTemplate filename curcontext variables = do
    parsed <- parseErbFile filename
    case parsed of
        Left err -> do
            let !msg = "template " ++ filename ++ " could not be parsed " ++ show err
            traceEventIO msg
            LOG.debugM "Erb.Compute" msg
            computeTemplateWRuby filename curcontext variables
        Right ast -> return $ rubyEvaluate variables curcontext ast

computeTemplateWRuby :: String -> String -> Map.Map String GeneralValue -> IO TemplateAnswer
computeTemplateWRuby filename curcontext variables = do
    let rubyvars = BB.string8 "{\n" <> mconcat (intersperse (BB.string8 ",\n") (concatMap toRuby (Map.toList variables))) <> BB.string8 "\n}\n" :: BB.Builder
        input = BB.stringUtf8 curcontext <> BB.charUtf8 '\n' <> BB.stringUtf8 filename <> BB.charUtf8 '\n' <> rubyvars :: BB.Builder
    rubyscriptpath <- do
        cabalPath <- getDataFileName "ruby/calcerb.rb"
        exists    <- fileExist cabalPath
        case exists of
            True -> return cabalPath
            False -> return "calcerb.rb"
    ret <- safeReadProcessTimeout "ruby" [rubyscriptpath] (BB.toLazyByteString input) 1000
    case ret of
        Just (Right x) -> return $ Right (BS.unpack x)
        Just (Left er) -> do
            (tmpfilename, tmphandle) <- openTempFile "/tmp" "templatefail"
            BS.hPut tmphandle (BB.toLazyByteString input)
            hClose tmphandle
            return $ Left $ er ++ " - for template " ++ filename ++ " input in " ++ tmpfilename
        Nothing -> do
            return $ Left "Process did not terminate"

minterc :: BB.Builder -> [BB.Builder] -> BB.Builder
minterc _ [] = mempty
minterc _ [a] = a
minterc !sep !(x:xs) = x <> foldl' minterc' mempty xs
    where
        minterc' !curbuilder !b  = curbuilder <> sep <> b

getTemplateFile :: String -> CatalogMonad String
getTemplateFile rawpath = do
    throwError rawpath
renderString :: String -> BB.Builder
renderString x = let !y = BB.stringUtf8 (show x) in y
{-
renderString cs = BB.char8 '"' <> foldMap escape cs <> BB.char8 '"'
    where
        escape '\\' = BB.string8 "\\\\"
        escape '\"' = BB.string8 "\\\""
        escape '\n' = BB.string8 "\\n"
        escape c    = BB.charUtf8 c
-}
toRuby (_, Left _) = []
toRuby (_, Right ResolvedUndefined) = []
toRuby (varname, Right varval) = [BB.charUtf8 '\t' <> renderString varname <> BB.string8 " => " <> toRuby' varval]
toRuby' (ResolvedString str) = renderString str
toRuby' (ResolvedInt i) = BB.charUtf8 '\'' <> BB.intDec (fromIntegral i) <> BB.charUtf8 '\''
toRuby' (ResolvedBool True) = BB.string8 "true"
toRuby' (ResolvedBool False) = BB.string8 "false"
--toRuby' (ResolvedArray rr) = BB.charUtf8 '[' <> mconcat (intercalate [BB.string8 ", "] (map (return . toRuby') rr)) <> BB.charUtf8 ']'
--toRuby' (ResolvedHash hh) = BB.string8 "{ " <> mconcat (intercalate [BB.string8 ", "] (map (\(varname, varval) -> [renderString varname <> BB.string8 " => " <> toRuby' varval]) hh)) <> BB.string8 " }"
toRuby' (ResolvedArray rr) = BB.charUtf8 '[' <> minterc (BB.string8 ", ") (map toRuby' rr) <> BB.charUtf8 ']'
toRuby' (ResolvedHash hh) = BB.string8 "{ " <> minterc (BB.string8 ", ") (map (\(varname, varval) -> renderString varname <> BB.string8 " => " <> toRuby' varval) hh) <> BB.string8 " }"
toRuby' ResolvedUndefined = BB.string8 ":undef"
toRuby' x = BB.string8 $ show x
