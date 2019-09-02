{-# LANGUAGE FlexibleContexts #-}

module DeShadow (deShadowPass) where

import Control.Monad.Reader
import Control.Monad.Writer
import Control.Monad.Except hiding (Except)

import Env
import Record
import Syntax
import Pass
import Fresh
import PPrint
import Cat

type DeShadowM a = ReaderT DeShadowEnv (FreshRT (Either Err)) a
type DeShadowCat a = WriterT [UDecl] (CatT (DeShadowEnv, FreshScope)
                          (Either Err)) a
type DeShadowEnv = (Env Name, Env Type)

deShadowPass :: UTopDecl -> TopPass (DeShadowEnv, FreshScope) UTopDecl
deShadowPass topDecl = case topDecl of
  TopDecl decl -> do ((), decls) <- catToTop $ deShadowDecl decl
                     return $ case decls of
                       [decl'] ->  TopDecl decl'
                       [] -> EvalCmd NoOp
                       _ -> error "Multiple decls not implemented"
  EvalCmd NoOp -> return (EvalCmd NoOp)
  EvalCmd (Command cmd expr) -> do
    expr' <- deShadowTop expr
    case cmd of Passes -> writeOutText $ "\n\nDeshadowed\n" ++ show expr'
                _ -> return ()
    return $ EvalCmd (Command cmd expr')
  where
    deShadowTop :: UExpr -> TopPass (DeShadowEnv, FreshScope) UExpr
    deShadowTop expr = do
      (env, scope) <- getEnv
      liftEither $ runFreshRT (runReaderT (deShadowExpr expr) env) scope

deShadowExpr :: UExpr -> DeShadowM UExpr
deShadowExpr expr = case expr of
  Lit x -> return (Lit x)
  Var v -> asks $ Var . lookupSubst v . fst
  PrimOp b [] args -> liftM (PrimOp b []) (traverse recur args)
  PrimOp _ ts _ -> error $ "Unexpected type args to primop " ++ pprint ts
  Decl decl body ->
    withCat (deShadowDecl decl) $ \_ [decl'] -> do
      body' <- recur body
      return $ Decl decl' body'
  Lam p body ->
    withCat (deShadowPat p) $ \p' decls -> do
      body' <- recur body
      return $ Lam p' $ wrapDecls decls body'
  App fexpr arg -> liftM2 App (recur fexpr) (recur arg)
  For p body ->
    withCat (deShadowPat p) $ \p' decls -> do
      body' <- recur body
      return $ For p' $ wrapDecls decls body'
  Get e v -> liftM2 Get (recur e) (recur v)
  TApp e ts -> liftM2 TApp (recur e) (mapM deShadowType ts)
  RecCon r -> liftM RecCon $ traverse recur r
  TabCon NoAnn xs -> liftM (TabCon NoAnn) (mapM recur xs)
  Annot body ty -> liftM2 Annot (recur body) (deShadowType ty)
  DerivAnnot e ann -> liftM2 DerivAnnot (recur e) (recur ann)
  SrcAnnot e pos -> liftM (flip SrcAnnot pos) (recur e)
  Pack e ty exTy -> liftM3 Pack (recur e) (deShadowType ty) (deShadowType exTy)
  TLam _ _ -> error "Not tlam in source language"
  IdxLit _ _ -> error "Not implemented"
  TabCon (Ann _) _ -> error "No annotated tabcon in source language"
  where recur = deShadowExpr

deShadowDecl :: UDecl -> DeShadowCat ()
deShadowDecl (Let p bound) = do
  bound' <- toCat $ deShadowExpr bound
  (p', decls) <- captureW $ deShadowPat p
  tell $ Let p' bound' : decls
deShadowDecl (Unpack b tv bound) = do
  bound' <- toCat $ deShadowExpr bound
  tv' <- looks $ rename tv . snd
  extend (asSnd (tv @> TypeVar tv'), tv'@>())
  ~(RecLeaf b', decls) <- captureW $ deShadowPat (RecLeaf b)
  tell $ Unpack b' tv' bound' : decls
deShadowDecl (TAlias v ty) = do  -- TODO: deal with capture
  ty' <- toCat $ deShadowType ty
  extend (asSnd (v @> ty'), v@>())

deShadowPat :: UPat -> DeShadowCat UPat
deShadowPat pat = traverse freshBinder pat

freshBinder :: UBinder -> DeShadowCat UBinder
freshBinder (v :> ann) = do
  shadowed <- looks $ (v `isin`) . snd
  if shadowed && v /= Name "_" 0
    then throw RepeatedVarErr (pprint v)
    else return ()
  ty' <- case ann of
           Ann ty -> liftM Ann $ toCat $ deShadowType ty
           NoAnn -> return NoAnn
  v' <- looks $ rename v . snd
  extend (asFst (v@>v'), v'@>())
  return (v' :> ty')

deShadowType :: Type -> DeShadowM Type
deShadowType ty = do
  subst <- asks $ snd
  return $ subType subst ty

subType :: Env Type -> Type -> Type
subType sub ty = case ty of
  BaseType _ -> ty
  TypeVar v  -> case envLookup sub v of Nothing  -> ty
                                        Just ty' -> ty'
  ArrType a b -> ArrType (recur a) (recur b)
  TabType a b -> TabType (recur a) (recur b)
  RecType r   -> RecType $ fmap recur r
  Exists body -> Exists $ recur body
  Forall ks body -> Forall ks (recur body)
  IdxSetLit _ -> ty
  BoundTVar _ -> ty
  where recur = subType sub

toCat :: DeShadowM a -> DeShadowCat a
toCat m = do
  (env, scope) <- look
  liftEither $ flip runFreshRT scope $ flip runReaderT env $ m

withCat :: DeShadowCat a -> (a -> [UDecl] -> DeShadowM b) -> DeShadowM b
withCat m cont = do
  env <- ask
  scope <- askFresh
  ((ans, decls), (env', scope')) <- liftEither $
                                      flip runCatT (env, scope) $ runWriterT m
  extendR env' $ localFresh (<> scope') $ cont ans decls

catToTop :: DeShadowCat a -> TopPass (DeShadowEnv, FreshScope) (a, [UDecl])
catToTop m = do
  env <- getEnv
  (ans, env') <- liftEither $ flip runCatT env $ runWriterT m
  putEnv env'
  return ans
