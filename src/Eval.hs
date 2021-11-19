{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE ImportQualifiedPost #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE TupleSections #-}
{-# LANGUAGE RecordWildCards #-}
{-# LANGUAGE BangPatterns #-}

module Eval where

import Control.Monad (unless)
import Control.Monad.Except (catchError, throwError)
import Control.Monad.IO.Class
import Control.Monad.State (gets, get, put)
import Data.Foldable (foldlM)
import Data.Functor ((<&>))
import Data.IORef (newIORef, readIORef, writeIORef)
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Maybe (fromMaybe)
import Data.Set (Set)
import Data.Set qualified as Set
import Data.Vector (Vector)
import Data.Vector qualified as Vector
import TextShow (TextShow(..))

import Types
import Errors

nil :: Expr
nil = LList []

mkContext :: [(Symbol, Expr)] -> Eval Context
mkContext pairs = liftIO (Context . Map.fromList <$> traverse (\(x, y) -> newIORef y <&> (x,)) pairs)

hasVar :: Symbol -> Eval Bool
hasVar i = do
  ctx <- gets getContext
  pure $ i `Map.member` ctx

lookupVar :: Symbol -> Eval Expr
lookupVar i = do
  ctx <- gets getContext
  case ctx Map.!? i of
    Nothing -> evalError $ "variable not in scope: " <> fromSymbol i
    Just x  -> liftIO $ readIORef x

specialOps :: Set Symbol
specialOps = Set.fromList
  [ "if"
  , "and"
  , "or"
  , "setq"
  , "defvar"
  , "defparameter"
  , "quote"
  , "defun"
  , "lambda"
  , "let"
  , "defmacro"
  , "progn"
  , "when"
  , "unless"
  , "block"
  , "return-from"
  , "go"
  , "tagbody"
  ]

setVar :: Symbol -> Expr -> Eval ()
setVar i val
  | i `Set.member` specialOps = evalError $ "error: " <> fromSymbol i <> " is a special operator and may not be overridden"
  | otherwise = do
    ctx <- gets getContext
    case ctx Map.!? i of
      Nothing -> do
        ref <- liftIO $ newIORef val
        put $ Context $ Map.insert i ref ctx
      Just ref -> liftIO $ writeIORef ref val

function :: Symbol -> Maybe Symbol -> Int -> [Expr] -> Eval Closure
function opName name n args = case args of
  (params:body) -> do
    context <- get
    let
      asSymbol :: Expr -> Eval Symbol
      asSymbol (LSymbol s) = pure s
      asSymbol _ = evalError $ fromSymbol opName <> ": invalid argument list"
    case params of
      LList params' -> do
        params'' <- traverse asSymbol params'
        pure $ Closure
          { closureName = name
          , closureParams = params''
          , closureVarargs = Nothing
          , closureBody = body
          , closureContext = context
          }
      LDottedList params' rest -> do
        params'' <- traverse asSymbol params'
        varargs <- asSymbol rest
        pure $ Closure
          { closureName = name
          , closureParams = params''
          , closureVarargs = Just varargs
          , closureBody = body
          , closureContext = context
          }
      LSymbol rest -> pure $ Closure
        { closureName = name
        , closureParams = []
        , closureVarargs = Just rest
        , closureBody = body
        , closureContext = context
        }
      _ -> evalError $ fromSymbol opName <> ": invalid argument list"
  _ -> numArgs opName n args

-- Evaluate a list of expressions and return the value of the final expression
progn :: [Expr] -> Eval Expr
progn [] = pure nil
progn [x] = eval x
progn (x:y) = eval x *> progn y

buildTagTable :: [Expr] -> Eval (Map TagName Int, Vector Expr)
buildTagTable = fmap collect . foldlM go (0, mempty, mempty)
  where
    collect (_, tagTable, exprs) = (tagTable, Vector.fromList (reverse exprs))
    go :: (Int, Map TagName Int, [Expr]) -> Expr -> Eval (Int, Map TagName Int, [Expr])
    go (i, tagTable, exprs) = \case
      -- normal symbols
      LSymbol sym -> pure (i, Map.insert (TagSymbol sym) i tagTable, exprs)
      LKeyword b -> pure (i, Map.insert (TagKeyword b) i tagTable, exprs)
      LInt n -> pure (i, Map.insert (TagInt n) i tagTable, exprs)
      -- NIL symbol
      LList [] -> pure (i, Map.insert (TagSymbol "nil") i tagTable, exprs)
      -- sexprs
      sx@(LList _) -> pure (i + 1, tagTable, sx:exprs)
      sx@(LDottedList _ _) -> pure (i + 1, tagTable, sx:exprs)
      e -> evalError $ "tagbody: invalid tag or form type: " <> renderType e

block :: Symbol -> Eval Expr -> Eval Expr
block blockName a =
  a `catchError` \case
    ReturnFrom target val
      | blockName == target -> pure val
      -- NOTE: non-matching block names should bubble up
    e -> throwError e

truthy :: Expr -> Bool
truthy = \case
  LBool b -> b
  _ -> True

condition :: Expr -> Eval Bool
condition cond = truthy <$> eval cond

eval :: Expr -> Eval Expr
eval (LInt n) = pure $ LInt n
eval (LBool b) = pure $ LBool b
eval (LChar b) = pure $ LChar b
eval (LKeyword b) = pure $ LKeyword b
eval (LString s) = pure $ LString s
eval (LFun f) = pure $ LFun f
eval (LMacro f) = pure $ LMacro f
eval (LBuiltin f) = pure $ LBuiltin f
eval (LSymbol sym) = lookupVar sym
eval (LDottedList xs _) = eval (LList xs)
eval (LList []) = pure nil
eval (LList (f:args)) =
  case f of
    LSymbol "if" -> do
      case args of
        [cond, x, y] -> do
          cond' <- condition cond
          if cond' then eval x else eval y
        _ -> numArgs "if" 3 args
    LSymbol "and" -> do
      let
        go [] = pure $ LBool True
        go [x] = pure x
        go (x:xs) = do
          x' <- condition x
          if x'
          then go xs
          else pure $ LBool False
      go args
    LSymbol "or" -> do
      let
        go [] = pure $ LBool False
        go [x] = pure x
        go (x:xs) = do
          x' <- eval x
          if truthy x'
          then pure x'
          else go xs
      go args
    -- NOTE: could be (defmacro setq (name val) (list 'set (list 'quote name) val)
    LSymbol "setq" -> do
      case args of
        [LSymbol e, val] -> do
          val' <- eval val
          setVar e val'
          pure val'
        [_, _] -> evalError "setq: expected symbol as variable name"
        _ -> numArgs "setq" 2 args
    LSymbol "defvar" -> do
      case args of
        [LSymbol e, val] -> do
          exists <- hasVar e
          unless exists $ setVar e =<< eval val
          pure $ LSymbol e
        [_, _] -> evalError "defvar: expected symbol as variable name"
        _ -> numArgs "defvar" 2 args
    LSymbol "defparameter" -> do
      case args of
        [LSymbol e, val] -> do
          setVar e =<< eval val
          pure $ LSymbol e
        [_, _] -> evalError "defvar: expected symbol as variable name"
        _ -> numArgs "defvar" 2 args
    -- NOTE: equivalent to (defmacro quote (x) (list 'quote x))
    LSymbol "quote" ->
      case args of
        [x] -> pure x
        _ -> numArgs "quote" 1 args
    LSymbol "defun" -> do
      case args of
        (LSymbol sym:spec) -> do
          fun <- LFun <$> function "defun" (Just sym) 2 spec
          setVar sym fun
          pure $ LSymbol sym
        (_:_) -> evalError "defun: expected symbol for function name"
        _ -> numArgs "defun" 2 args
    LSymbol "lambda" -> LFun <$> function "lambda" Nothing 1 args
    LSymbol "let" -> do
      case args of
        [] -> numArgs "let" 1 args
        (LList xs:body) -> do
          let
            getBinding (LList [LSymbol name, val]) = (name,) <$> eval val
            getBinding (LSymbol name) = pure (name, nil)
            getBinding _ = evalError "let: invalid variable specification"
          binds <- mkContext =<< traverse getBinding xs
          localContext (<> binds) $ progn body
        _ -> evalError "let: invalid variable specification"
    LSymbol "defmacro" ->
      case args of
        (LSymbol sym:spec) -> do
          fun <- LMacro <$> function "defmacro" (Just sym) 2 spec
          setVar sym fun
          pure $ LSymbol sym
        (_:_) -> evalError "defmacro: expected symbol for macro name"
        _ -> numArgs "defmacro" 2 args
    LSymbol "progn" -> progn args
    LSymbol "when" -> do
      case args of
        (cond:body) -> do
          cond' <- condition cond
          if cond' then progn body else pure nil
        _ -> numArgsAtLeast "when" 1 args
    LSymbol "unless" -> do
      case args of
        (cond:body) -> do
          cond' <- condition cond
          if not cond' then progn body else pure nil
        _ -> numArgsAtLeast "unless" 1 args
    -- NOTE: allowed block names are nil and symbols
    LSymbol "block" -> do
      case args of
        (LSymbol blockName:body) -> block blockName $ progn body
        (LList []:body) -> block "nil" $ progn body
        (_:_) -> evalError "block: expected symbol as block name"
        _ -> numArgsAtLeast "block" 1 args
    LSymbol "return-from" -> do
      case args of
        [LSymbol blockName] -> throwError $ ReturnFrom blockName nil
        [LSymbol blockName, val] -> throwError $ ReturnFrom blockName val
        -- TODO: this should be generalized; 'nil and () are the same in CL
        [LList []] -> throwError $ ReturnFrom "nil" nil
        [LList [], val] -> throwError $ ReturnFrom "nil" val
        [_] -> evalError "return-from: expected symbol for block name"
        [_, _] -> evalError "return-from: expected symbol for block name"
        _ -> numArgsBound "return-from" (1, 2) args
    LSymbol "go" -> do
      case args of
        [LSymbol sym] -> throwError $ TagGo $ TagSymbol sym
        [LKeyword b] -> throwError $ TagGo $ TagKeyword b
        [LInt n] -> throwError $ TagGo $ TagInt n
        [LList []] -> throwError $ TagGo $ TagSymbol "nil"
        [e] -> evalError $ "go: invalid tag type: " <> renderType e
        _ -> numArgs "go" 1 args
    -- NOTE: allowed tags are numbers, symbols, keywords, and nil
    LSymbol "tagbody" -> do
      -- collect arguments into vectors, construct table mapping symbols to
      -- indices
      -- (watch out for symbols on end and consecutive symbols)
      -- evaluate progn at index 0
      -- catch any TagGo exceptions, and if there's an appropriate tag name in
      -- scope, start evaluating there
      (table, exprs) <- buildTagTable args
      let
        len = Vector.length exprs
        runAt !ix =
          if ix < 0 || ix >= len
          then pure ()
          else eval (exprs Vector.! ix) *> runAt (ix + 1)
        go !ix =
          runAt ix `catchError` \case
            TagGo tagName
              | Just ix' <- table Map.!? tagName -> go ix'
            e -> throwError e
      go 0
      pure nil
    _ -> eval f >>= \case
      LBuiltin f' -> f' =<< traverse eval args
      LFun f' -> apply f' =<< traverse eval args
      LMacro m -> eval =<< apply m args
      e -> evalError $ "expected function in s-expr: " <> showt e

apply :: Closure -> [Expr] -> Eval Expr
apply Closure{..} args = do
  let got = length args
      expected = length closureParams
      name = fromMaybe "<anonymous>" closureName
  binds <- case closureVarargs of
    Nothing
      | got /= expected -> numArgs name expected args
      | otherwise -> mkContext (zip closureParams args)
    Just rest
      | got < expected -> numArgsAtLeast name expected args
      | otherwise -> do
          let (mainArgs, restArgs) = splitAt expected args
          mkContext (zip closureParams mainArgs <> [(rest, LList restArgs)])
  localContext (\c -> closureContext <> c <> binds) $ do
    progn closureBody `catchError` \case
      -- all (return-from)s need to be caught, or else we could bubble out of
      -- the current function! this is contrasted with `block`, which should
      -- let any (return-from)s with a different label to bubble up
      ReturnFrom blockName val
        | Just blockName == closureName -> pure val
        | otherwise -> evalError $ fromSymbol name <> ": error returning from block " <> showt (fromSymbol blockName) <> ": no such block in scope"
      TagGo tagName -> evalError $ fromSymbol name <> ": error going to tag " <> renderTagName tagName <> ": no such tag in scope"
      e -> throwError e

