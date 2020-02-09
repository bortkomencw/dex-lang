-- Copyright 2019 Google LLC
--
-- Use of this source code is governed by a BSD-style
-- license that can be found in the LICENSE file or at
-- https://developers.google.com/open-source/licenses/bsd

{-# LANGUAGE TypeSynonymInstances #-}
{-# LANGUAGE FlexibleInstances #-}

module Subst (Subst, subst, reduceAtom, nRecGet, nTabGet, nTabGetLit) where

import Data.Foldable

import Env
import Record
import Syntax
import PPrint
import Fresh
import Array
import Type

class Subst a where
  subst :: (SubstEnv, Scope) -> a -> a

instance (TraversableExpr expr, Subst ty, Subst e, Subst lam)
         => Subst (expr ty e lam) where
  subst env expr = fmapExpr expr (subst env) (subst env) (subst env)

instance Subst Expr where
  subst env@(_, scope) expr = case expr of
    Decl decl body -> Decl decl' (subst (env <> env') body)
      where (decl', env') = refreshDecl scope (subst env decl)
    CExpr e  -> CExpr $ subst env e
    Atom  x  -> Atom  $ subst env x

instance Subst Atom where
  subst env@(sub, scope) atom = case atom of
    Var v -> case envLookup sub v of
      Nothing -> Var $ fmap (subst env) v
      Just (L x') -> subst (mempty, scope) x'
      Just (T _ ) -> error "Expected let-bound variable"
    TLam tvs body -> TLam tvs' $ subst (env <> env') body
      where (tvs', env') = refreshTBinders scope tvs
    -- This case is ensure indexing is reduced if possible
    PrimCon (TabGet x i) -> nTabGet (subst env x) (subst env i)
    PrimCon con -> reduceAtom $ PrimCon $ subst env con

reduceAtom :: Atom -> Atom
reduceAtom atom = case atom of
  PrimCon (RecGet e i) -> nRecGet (reduceAtom e) i
  PrimCon (TabGet e i) -> nTabGet (reduceAtom e) i
  _ -> atom

nRecGet ::  Atom -> RecField -> Atom
nRecGet (PrimCon (RecCon r)) i = recGet r i
nRecGet x i = PrimCon $ RecGet x i

nTabGet :: Atom -> Atom -> Atom
nTabGet x i = case i of
  PrimCon (AsIdx _ (PrimCon (Lit (IntLit i')))) -> nTabGetLit x i'
  _ -> PrimCon $ TabGet x i

nTabGetLit :: Atom -> Int -> Atom
nTabGetLit atom i = case atom of
  PrimCon (ArrayRef (TabType _ ty) ref) -> PrimCon $ ArrayRef ty (subArray i ref)
  PrimCon (AFor _ body)                 -> indexSubst i [] body
  _ -> PrimCon $ TabGet atom i'
    where i' = PrimCon $ AsIdx n $ PrimCon $ Lit (IntLit i)
          (TabType (IdxSetLit n) _) = getType atom

indexSubst :: Int -> [()] -> Atom -> Atom
indexSubst i stack atom = case atom of
  PrimCon con -> case con of
    AFor n body -> PrimCon $ AFor n $ indexSubst i (():stack) body
    AGet x -> case stack of
      []        -> nTabGetLit x i
      ():stack' -> PrimCon $ AGet $ indexSubst i stack' x
    _ -> PrimCon $ fmapExpr con id (indexSubst i stack) (error "unexpected lambda")
  _ -> error "Unused index"

instance Subst LamExpr where
  subst env@(_, scope) (LamExpr b body) = LamExpr b' body'
    where (b', env') = refreshBinder scope (subst env b)
          body' = subst (env <> env') body

refreshDecl :: Env () -> Decl -> (Decl, (SubstEnv, Scope))
refreshDecl scope decl = case decl of
  Let b bound -> (Let b' bound, env)
    where (b', env) = refreshBinder scope (subst env b)

refreshBinder :: Env () -> Var -> (Var, (SubstEnv, Scope))
refreshBinder scope b = (b', env')
  where b' = rename b scope
        env' = (b@>L (Var b'), b'@>())

refreshTBinders :: Env () -> [TVar] -> ([TVar], (SubstEnv, Scope))
refreshTBinders scope bs = (bs', env')
  where (bs', scope') = renames bs scope
        env' = (fold [b @> T (TypeVar b') | (b,b') <- zip bs bs'], scope')

instance Subst Type where
   subst env@(sub, _) ty = case ty of
    BaseType _ -> ty
    TypeVar v ->
      case envLookup sub v of
        Nothing      -> ty
        Just (T ty') -> ty'
        Just (L _)   -> error $ "Shadowed type var: " ++ pprint v
    ArrType l a b -> ArrType (recur l) (recur a) (recur b)
    TabType a b -> TabType (recur a) (recur b)
    RecType r   -> RecType $ fmap recur r
    TypeApp f args -> TypeApp (recur f) (map recur args)
    Forall    ks body -> Forall    ks (recur body)
    TypeAlias ks body -> TypeAlias ks (recur body)
    Monad eff a -> Monad (fmap recur eff) (recur a)
    Lens a b    -> Lens (recur a) (recur b)
    IdxSetLit _ -> ty
    BoundTVar _ -> ty
    Mult _      -> ty
    NoAnn       -> NoAnn
    where recur = subst env

instance Subst Decl where
  subst env decl = case decl of
    Let    b    bound -> Let    (subst env b)    (subst env bound)

instance Subst Var where
  subst env (v:>ty) = v:> subst env ty

instance Subst a => Subst (RecTree a) where
  subst env p = fmap (subst env) p

instance (Subst a, Subst b) => Subst (a, b) where
  subst env (x, y) = (subst env x, subst env y)

instance Subst a => Subst (Env a) where
  subst env xs = fmap (subst env) xs

instance (Subst a, Subst b) => Subst (LorT a b) where
  subst env (L x) = L (subst env x)
  subst env (T y) = T (subst env y)

instance (Subst a, Subst b) => Subst (Either a b)where
  subst env (Left  x) = Left  (subst env x)
  subst env (Right x) = Right (subst env x)
