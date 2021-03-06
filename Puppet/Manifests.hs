{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE GADTs            #-}
{-# LANGUAGE LambdaCase       #-}
module Puppet.Manifests (filterStatements) where

import           Control.Applicative
import           Control.Lens
import           Control.Monad.Except
import qualified Data.Either.Strict               as S
import qualified Data.HashMap.Strict              as HM
import qualified Data.Text                        as T
import qualified Data.Text.Encoding               as T
import           Data.Tuple.Strict
import qualified Data.Vector                      as V
import           Text.Regex.PCRE.ByteString.Utils

import           Puppet.Interpreter.Types
import           Puppet.Parser.Types
import           Puppet.PP

-- TODO pre-triage stuff
filterStatements :: TopLevelType -> T.Text -> V.Vector Statement -> IO (S.Either PrettyError Statement)
-- the most complicated case, node matching
filterStatements TopNode ndename stmts =
    -- this operation should probably get cached
    let (!spurious, !directnodes, !regexpmatches, !defaultnode) = V.foldl' triage (V.empty, HM.empty, V.empty, Nothing) stmts
        triage curstuff n@(NodeDeclaration (NodeDecl (NodeName !nm) _ _ _)) = curstuff & _2 . at nm ?~ n
        triage curstuff n@(NodeDeclaration (NodeDecl (NodeMatch (CompRegex _ !rg)) _ _ _)) = curstuff & _3 %~ (|> (rg :!: n))
        triage curstuff n@(NodeDeclaration (NodeDecl  NodeDefault _  _ _)) = curstuff & _4 ?~ n
        triage curstuff x = curstuff & _1 %~ (|> x)
        bsnodename = T.encodeUtf8 ndename
        checkRegexp :: [Pair Regex Statement] -> ExceptT PrettyError IO (Maybe Statement)
        checkRegexp [] = return Nothing
        checkRegexp ((regexp  :!: s):xs) =
            case execute' regexp bsnodename of
                Left rr -> throwError (PrettyError ("Regexp match error:" <+> text (show rr)))
                Right Nothing -> checkRegexp xs
                Right (Just _) -> return (Just s)
        strictEither (Left x) = S.Left x
        strictEither (Right x) = S.Right x
    in case directnodes ^. at ndename of -- check if there is a node specifically called after my name
           Just r  -> return (S.Right (TopContainer spurious r))
           Nothing -> fmap strictEither $ runExceptT $ do
                regexpMatchM <- checkRegexp (V.toList regexpmatches) -- match regexps
                case regexpMatchM <|> defaultnode of -- check for regexp matches or use the default node
                    Just r -> return (TopContainer spurious r)
                    Nothing -> throwError (PrettyError ("Couldn't find node" <+> ttext ndename))
filterStatements x ndename stmts =
    let (!spurious, !defines, !classes) = V.foldl' triage (V.empty, HM.empty, HM.empty) stmts
        triage curstuff n@(ClassDeclaration (ClassDecl cname _ _ _ _)) = curstuff & _3 . at cname ?~ n
        triage curstuff n@(DefineDeclaration (DefineDecl cname _ _ _)) = curstuff & _2 . at cname ?~ n
        triage curstuff n = curstuff & _1 %~ (|> n)
        tc n = if V.null spurious
                   then n
                   else TopContainer spurious n
    in  case x of
            TopNode -> return (S.Left "Case already covered, shoudln't happen in Puppet.Manifests")
            TopDefine -> case defines ^. at ndename of
                             Just n -> return (S.Right (tc n))
                             Nothing -> return (S.Left (PrettyError ("Couldn't find define " <+> ttext ndename)))
            TopClass -> case classes ^. at ndename of
                            Just n -> return (S.Right (tc n))
                            Nothing -> return (S.Left (PrettyError ("Couldn't find class " <+> ttext ndename)))
