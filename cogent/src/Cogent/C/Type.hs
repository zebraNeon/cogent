--
-- Copyright 2019, Data61
-- Commonwealth Scientific and Industrial Research Organisation (CSIRO)
-- ABN 41 687 119 230.
--
-- This software may be distributed and modified according to the terms of
-- the GNU General Public License version 2. Note that NO WARRANTY is provided.
-- See "LICENSE_GPLv2.txt" for details.
--
-- @TAG(DATA61_GPL)
--

{- LANGUAGE AllowAmbiguousTypes -}
{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DeriveFunctor #-}
{-# LANGUAGE ExistentialQuantification #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
--{-# LANGUAGE ImpredicativeTypes #-}
{-# LANGUAGE KindSignatures #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE MultiWayIf #-}
#if __GLASGOW_HASKELL__ < 709
{-# LANGUAGE OverlappingInstances #-}
#endif
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE PatternGuards #-}
{-# LANGUAGE QuasiQuotes #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE StandaloneDeriving #-}
{-# LANGUAGE TemplateHaskell #-}
{-# LANGUAGE TupleSections #-}
{-# LANGUAGE TypeFamilies #-}
{-# LANGUAGE TypeOperators #-}
{-# LANGUAGE UndecidableInstances #-}
{-# LANGUAGE ViewPatterns #-}
{-# OPTIONS_GHC -fno-warn-orphans -Wwarn #-}

module Cogent.C.Type where

import           Cogent.C.Monad
import           Cogent.C.Syntax       as C   hiding (BinOp (..), UnOp (..))
import qualified Cogent.C.Syntax       as C   (BinOp (..), UnOp (..))
import           Cogent.Compiler
import           Cogent.Common.Syntax  as Syn
import           Cogent.Common.Types   as Typ
import           Cogent.Core           as CC
import           Cogent.Inference             (kindcheck_)
import           Cogent.Isabelle.Deep
import           Cogent.Mono                  (Instance)
import           Cogent.Normal                (isAtom)
import           Cogent.Surface               (noPos)
import           Cogent.Util                  (behead, decap, extTup2l, extTup3r, first3, secondM, toCName, whenM, flip3)
import qualified Data.DList          as DList
import           Data.Nat            as Nat
import           Data.Vec            as Vec   hiding (repeat, zipWith)

import           Control.Applicative          hiding (empty)
import           Control.Arrow                       ((***), (&&&), second)
import           Control.Monad.RWS.Strict     hiding (mapM, mapM_, Dual, (<>), Product, Sum)
import           Data.Char                    (isAlphaNum, toUpper)
#if __GLASGOW_HASKELL__ < 709
import           Data.Foldable                (mapM_)
#endif
import           Data.Functor.Compose
import           Data.IntMap         as IM    (delete, mapKeys)
import qualified Data.List           as L
import           Data.Loc                     (noLoc)  -- FIXME: remove
import qualified Data.Map            as M
import           Data.Maybe                   (catMaybes, fromJust)
import           Data.Monoid                  ((<>))
-- import           Data.Semigroup.Monad
-- import           Data.Semigroup.Reducer       (foldReduce)
import qualified Data.Set            as S
import           Data.String
import           Data.Traversable             (mapM)
import           Data.Tuple                   (swap)
#if __GLASGOW_HASKELL__ < 709
import           Prelude             as P     hiding (mapM, mapM_)
#else
import           Prelude             as P     hiding (mapM)
#endif
import           System.IO (Handle, hPutChar)
import qualified Text.PrettyPrint.ANSI.Leijen as PP hiding ((<$>), (<>))
import           Lens.Micro                   hiding (at)
import           Lens.Micro.Mtl               hiding (assign)
import           Lens.Micro.TH
import           Control.Monad.Identity (runIdentity)
-- import Debug.Trace
import Unsafe.Coerce (unsafeCoerce)


-- * Type generation

genTyDecl :: (StrlType, CId) -> [TypeName] -> [CExtDecl]
genTyDecl (Record x, n) _ = [CDecl $ CStructDecl n (map (second Just . swap) x), genTySynDecl (n, CStruct n)]
genTyDecl (RecordL layout, n) _ =
  let size      = dataLayoutSizeBytes layout
      arrayType = CArray (CInt False CIntT) (CArraySize $ CConst $ CNumConst size (CInt False CIntT) DEC)
  in
    if size == 0
      then []
      else [CDecl $ CStructDecl n [(arrayType, Just "data")], genTySynDecl (n, CStruct n)]
genTyDecl (Product t1 t2, n) _ = [CDecl $ CStructDecl n [(t1, Just p1), (t2, Just p2)]]
genTyDecl (Variant x, n) _ = case __cogent_funion_for_variants of
  False -> [CDecl $ CStructDecl n ((CIdent tagsT, Just fieldTag) : map (second Just . swap) (M.toList x)),
            genTySynDecl (n, CStruct n)]
  True  -> [CDecl $ CStructDecl n [(CIdent tagsT, Just fieldTag), (CUnion Nothing $ Just (map swap (M.toList x)), Nothing)],
            genTySynDecl (n, CStruct n)]
genTyDecl (Function t1 t2, n) tns =
  if n `elem` tns then []
                  else [CDecl $ CTypeDecl (CIdent fty) [n]]
  where fty = if __cogent_funtyped_func_enum then untypedFuncEnum else unitT
#ifdef BUILTIN_ARRAYS
genTyDecl (Array t, n) _ = [CDecl $ CVarDecl t n True Nothing]
genTyDecl (ArrayL layout, n) _ =
  let elemSize = dataLayoutSizeBytes layout
      dataType = CPtr (CInt False CIntT)
   in if elemSize == 0
         then []
         else [CDecl $ CStructDecl n [(dataType, Just "data")], genTySynDecl (n, CStruct n)]
#endif
genTyDecl (AbsType x, n) _ = [CMacro $ "#include <abstract/" ++ x ++ ".h>"]

genTySynDecl :: (TypeName, CType) -> CExtDecl
genTySynDecl (n,t) = CDecl $ CTypeDecl t [n]

lookupStrlTypeCId :: StrlType -> Gen v (Maybe CId)
lookupStrlTypeCId st = M.lookup st <$> use cTypeDefMap

-- Lookup a structure and return its name, or create a new entry.
getStrlTypeCId :: StrlType -> Gen v CId
getStrlTypeCId st = do lookupStrlTypeCId st >>= \case
                         Nothing -> do t <- freshGlobalCId 't'
                                       cTypeDefs %= ((st,t):)  -- NOTE: add a new entry at the front
                                       cTypeDefMap %= M.insert st t
                                       return t
                         Just t  -> return t

{-# RULES
"monad-left-id" [~] forall x k. return x >>= k = k x
"monad-right-id" [~] forall k. k >>= return = k
"monad-assoc" [~] forall j k l. (j >>= k) >>= l = j >>= (\x -> k x >>= l)
  #-}

-- FIXME: prove it! / zilinc
instance Monad (Compose (Gen v) Maybe) where
  return = Compose . return . return
  (Compose ma) >>= f = Compose (ma >>= \case Nothing -> return Nothing
                                             Just a  -> getCompose (f a))

lookupTypeCId :: CC.Type 'Zero VarName -> Gen v (Maybe CId)
lookupTypeCId (TVar     {}) = __impossible "lookupTypeCId"
lookupTypeCId (TVarBang {}) = __impossible "lookupTypeCId"
lookupTypeCId (TCon tn [] _) = fmap (const tn) . M.lookup tn <$> use absTypes
lookupTypeCId (TCon tn ts _) = getCompose (forM ts (\t -> (if isUnboxed t then ('u':) else id) <$> (Compose . lookupTypeCId) t) >>= \ts' ->
                                           Compose (M.lookup tn <$> use absTypes) >>= \tss ->
                                           Compose $ return (if ts' `S.member` tss
                                                               then return $ tn ++ "_" ++ L.intercalate "_" ts'
                                                               else Nothing))
lookupTypeCId (TProduct t1 t2) =
  getCompose (Compose . lookupStrlTypeCId =<<
    Record <$> (P.zip [p1,p2] <$> mapM (Compose . lookupType) [t1,t2]))
lookupTypeCId (TSum fs) = getCompose (Compose . lookupStrlTypeCId =<< Variant . M.fromList <$> mapM (secondM (Compose . lookupType) . second fst) fs)
lookupTypeCId (TFun t1 t2) = getCompose (Compose . lookupStrlTypeCId =<< Function <$> (Compose . lookupType) t1 <*> (Compose . lookupType) t2)  -- Use the enum type for function dispatching
lookupTypeCId (TRecord fs Unboxed) =
  getCompose (Compose . lookupStrlTypeCId =<<
    Record <$> (mapM (\(a,(b,_)) -> (a,) <$> (Compose . lookupType) b) fs))
lookupTypeCId (TRecord _  (Boxed _ l@(Layout RecordLayout {}))) = lookupStrlTypeCId (RecordL l)
lookupTypeCId (TRecord fs (Boxed _ CLayout)) =
  getCompose (Compose . lookupStrlTypeCId =<<
    Record <$> (mapM (\(a,(b,_)) -> (a,) <$> (Compose . lookupType) b) fs))
lookupTypeCId cogentType@(TRecord _ (Boxed _ _)) = __impossible "lookupTypeCId: record with non-record layout"
#ifdef BUILTIN_ARRAYS
lookupTypeCId (TArray t n Unboxed _) = getCompose (Compose . lookupStrlTypeCId =<< Array <$> (Compose . lookupType) t)
lookupTypeCId (TArray t n (Boxed _ l) _) = lookupStrlTypeCId (ArrayL l)
#endif
lookupTypeCId t = Just <$> typeCId t

-- XXX | -- NOTE: (Monad (Gen v), Reducer (Maybe a) (First a)) => Reducer (Gen v (Maybe a)) (Mon (Gen v) (First a)) / zilinc
-- XXX | -- If none of a type's parts are used, then getFirst -> None; otherwise getFirst -> Just cid
-- XXX | typeCIdUsage :: forall v. CC.Type Zero -> Gen v (First CId)
-- XXX | typeCIdUsage (TVar     {}) = __impossible "typeCIdUsage"
-- XXX | typeCIdUsage (TVarBang {}) = __impossible "typeCIdUsage"
-- XXX | typeCIdUsage (TCon tn [] _) = fmap (const tn) <$> (First . M.lookup tn <$> use absTypes)
-- XXX | typeCIdUsage (TCon tn ts _) = getMon $ foldReduce (map ((getFirst <$>) . typeCIdUsage) ts :: [Gen v (Maybe CId)])
-- XXX | typeCIdUsage (TProduct t1 t2) = getMon $ foldReduce [getFirst <$> typeCIdUsage t1 :: Gen v (Maybe CId), getFirst <$> typeCIdUsage t2]
-- XXX | typeCIdUsage (TSum fs) = getMon $ foldReduce (map ((getFirst <$>) . typeCIdUsage . snd) fs :: [Gen v (Maybe CId)])
-- XXX | typeCIdUsage (TFun t1 t2) = getMon $ foldReduce [getFirst <$> typeCIdUsage t1 :: Gen v (Maybe CId), getFirst <$> typeCIdUsage t2]
-- XXX | typeCIdUsage (TRecord fs s) = getMon $ foldReduce (map ((getFirst <$>) . typeCIdUsage . fst . snd) fs :: [Gen v (Maybe CId)])
-- XXX | typeCIdUsage t = return $ First Nothing  -- base types

typeCId :: CC.Type 'Zero VarName -> Gen v CId
typeCId t = use custTypeGen >>= \ctg ->
            case M.lookup t ctg of
              Just (n,_) -> return n
              Nothing ->
                (if __cogent_fflatten_nestings then typeCIdFlat else typeCId') t >>= \n ->
                when (isUnstable t) (typeCorres %= DList.cons (toCName n, t)) >>
                return n
  where
    typeCId' :: CC.Type 'Zero VarName -> Gen v CId
    typeCId' (TVar     {}) = __impossible "typeCId' (in typeCId)"
    typeCId' (TVarBang {}) = __impossible "typeCId' (in typeCId)"
    typeCId' (TPrim pt) | pt == Boolean = return boolT
                        | otherwise = primCId <$> pure pt
    typeCId' (TString) = return "char"
    typeCId' (TCon tn [] _) = do
      absTypes %= M.insert tn (S.singleton []) -- NOTE: Since it's non-parametric, it can have only one entry which is always the same / zilinc
      -- getStrlTypeCId (AbsType tn)  -- NOTE: Monomorphic abstract types will remain undefined! / zilinc
      return tn
    typeCId' (TCon tn ts _) = do  -- mapM typeCId ts >>= \ts' -> return (tn ++ "_" ++ L.intercalate "_" ts')
      ts' <- forM ts $ \t -> (if isUnboxed t then ('u':) else id) <$> typeCId t
      absTypes %= M.insertWith S.union tn (S.singleton ts')
      let tn' = tn ++ "_" ++ L.intercalate "_" ts'
          ins Nothing  = Just $ S.singleton ts'
          ins (Just s) = Just $ S.insert ts' s
      absTypes %= M.alter ins tn
      lookupStrlTypeCId (AbsType tn') >>= \case
        Nothing -> do cTypeDefs %= ((AbsType tn', tn'):)  -- This tn' should never be used!
                      cTypeDefMap %= M.insert (AbsType tn') tn'
        Just _  -> return ()
      return tn'
    typeCId' (TProduct t1 t2) = getStrlTypeCId =<< Record <$> (P.zip [p1,p2] <$> mapM genType [t1,t2])
    typeCId' (TSum fs) = getStrlTypeCId =<< Variant . M.fromList <$> mapM (secondM genType . second fst) fs
    typeCId' (TFun t1 t2) = getStrlTypeCId =<< Function <$> genType t1 <*> genType t2  -- Use the enum type for function dispatching
    typeCId' (TRecord fs Unboxed) = getStrlTypeCId =<< Record <$> (mapM (\(a,(b,_)) -> (a,) <$> genType b) fs)
    typeCId' (TRecord fs (Boxed _ l)) =
      case l of
        Layout RecordLayout {} -> getStrlTypeCId (RecordL l)
        CLayout -> getStrlTypeCId =<< Record <$> (mapM (\(a,(b,_)) -> (a,) <$> genType b) fs)
        _ -> __impossible "Tried to get the c-type of a record with a non-record layout"
    typeCId' (TUnit) = return unitT
#ifdef BUILTIN_ARRAYS
    typeCId' (TArray t l Unboxed _) = getStrlTypeCId =<< Array <$> genType t
    typeCId' (TArray t l (Boxed _ al) _) =
      case al of
        Layout ArrayLayout {} -> getStrlTypeCId (ArrayL al)
        CLayout -> getStrlTypeCId =<< Array <$> genType t
        _ -> __impossible "Tried to get the c-type of an array with a non-array record"
#endif

    typeCIdFlat :: CC.Type 'Zero VarName -> Gen v CId
    typeCIdFlat (TProduct t1 t2) = do
      ts' <- mapM genType [t1,t2]
      fss <- forM (P.zip3 [p1,p2] [t1,t2] ts') $ \(f,t,t') -> case t' of
        CPtr _ -> return [(f,t')]
        _      -> collFields f t
      getStrlTypeCId $ Record (concat fss)
    -- typeCIdFlat (TSum fs) = __todo  -- Don't flatten variants for now. It's not clear how to incorporate with --funion-for-variants
    typeCIdFlat (TRecord fs Unboxed) = do
      let (fns,ts) = P.unzip $ P.map (second fst) fs
      ts' <- mapM genType ts
      fss <- forM (P.zip3 fns ts ts') $ \(f,t,t') -> case t' of
        CPtr _ -> return [(f,t')]
        _      -> collFields f t
      getStrlTypeCId $ Record (concat fss)
    typeCIdFlat t = typeCId' t

    collFields :: FieldName -> CC.Type 'Zero VarName -> Gen v [(CId, CType)]
    collFields fn (TProduct t1 t2) = concat <$> zipWithM collFields (P.map ((fn ++ "_") ++) [p1,p2]) [t1,t2]
    collFields fn (TRecord fs _) = let (fns,ts) = P.unzip (P.map (second fst) fs) in concat <$> zipWithM collFields (P.map ((fn ++ "_") ++) fns) ts
    collFields fn t = (:[]) . (fn,) <$> genType t

    isUnstable :: CC.Type 'Zero VarName -> Bool
    isUnstable (TCon {}) = True  -- NOTE: we relax the rule here to generate all abstract types in the table / zilinc (28/5/15)
    -- XXX | isUnstable (TCon _ (_:_) _) = True
    isUnstable (TProduct {}) = True
    isUnstable (TSum _) = True
    isUnstable (TRecord {}) = True
#ifdef BUILTIN_ARRAYS
    isUnstable (TArray {}) = True
#endif
    isUnstable _ = False

-- Made for Glue
absTypeCId :: CC.Type 'Zero VarName -> Gen v CId
absTypeCId (TCon tn [] _) = return tn
absTypeCId (TCon tn ts _) = do
  ts' <- forM ts $ \t -> (if isUnboxed t then ('u':) else id) <$> typeCId t
  return (tn ++ "_" ++ L.intercalate "_" ts')
absTypeCId _ = __impossible "absTypeCId"

-- Returns the right C type
genType :: CC.Type 'Zero VarName -> Gen v CType
genType t@(TRecord _ s)  | s /= Unboxed = CPtr . CIdent <$> typeCId t
  -- c.f. genTypeA
  -- This puts the pointer around boxed cogent-types
genType t@(TString)                     = CPtr . CIdent <$> typeCId t
genType t@(TCon _ _ s)   | s /= Unboxed = CPtr . CIdent <$> typeCId t
#ifdef BUILTIN_ARRAYS
genType t@(TArray elt l s _)
  | (Boxed _ CLayout) <- s = CPtr <$> genType elt  -- If it's heap-allocated without layout specified
  -- we get rid of unused info here, e.g. array length, hole location
  | (Boxed _ al)      <- s = CPtr . CIdent <$> typeCId (simplifyType t) -- we are going to declare it as a type
  | otherwise              = CArray <$> genType elt <*> (CArraySize <$> genLExpr l)
#endif
genType t                               = CIdent <$> typeCId t

-- Helper function for remove unnecessary info for cogent types
simplifyType :: CC.Type 'Zero VarName -> CC.Type 'Zero VarName
#ifdef BUILTIN_ARRAYS
simplifyType (TArray elt _ (Boxed _ (Layout (ArrayLayout l _))) _) =
    TArray elt (LILit 0 U32) (Boxed undefined (Layout (ArrayLayout l noPos))) Nothing
#endif
simplifyType x = x

-- The following two functions have different behaviours than the `genType' function
-- in certain scenarios

-- Used when generating a type for an argument to a function
genTypeA :: CC.Type 'Zero VarName -> Gen v CType
genTypeA t@(TRecord _ Unboxed) | __cogent_funboxed_arg_by_ref = CPtr . CIdent <$> typeCId t  -- TODO: sizeof
genTypeA t = genType t

-- It will generate a pointer type for an array, instead of the static-sized array type
genTypeP :: CC.Type 'Zero VarName -> Gen v CType
#ifdef BUILTIN_ARRAYS
genTypeP (TArray telm l Unboxed _) = CPtr <$> genTypeP telm  -- FIXME: what about boxed? / zilinc
#endif
genTypeP t = genType t


-- TODO(dagent): this seems wrong with respect to Dargent
lookupType :: CC.Type 'Zero VarName -> Gen v (Maybe CType)
lookupType t@(TRecord _ s)    | s /= Unboxed = getCompose (CPtr . CIdent <$> Compose (lookupTypeCId t))
lookupType t@(TString)                       = getCompose (CPtr . CIdent <$> Compose (lookupTypeCId t))
lookupType t@(TCon _ _ s)     | s /= Unboxed = getCompose (CPtr . CIdent <$> Compose (lookupTypeCId t))
#ifdef BUILTIN_ARRAYS
lookupType t@(TArray _ _ s _) | s /= Unboxed = getCompose (CPtr . CIdent <$> Compose (lookupTypeCId t))
                              | otherwise    = getCompose (CPtr . CIdent <$> Compose (lookupTypeCId t))
#endif
lookupType t                                 = getCompose (       CIdent <$> Compose (lookupTypeCId t))



-- *****************************************************************************
-- * LExpr generation

genLExpr :: CC.LExpr 'Zero VarName -> Gen v CExpr
genLExpr (LVariable var        ) = __todo "genLExpr"
genLExpr (LFun      fn []  nt  ) = __todo "genLExpr"
genLExpr (LFun      fn tys nt  ) = __todo "genLExpr"
genLExpr (LOp       opr es     ) = genOp opr (CC.TPrim U32) <$> mapM genLExpr es  -- FIXME: we assume it's U32 for now / zilinc
genLExpr (LApp      e1 e2      ) = __todo "genLExpr"
genLExpr (LCon      tag e t    ) = __todo "genLExpr"
genLExpr (LUnit                ) = __todo "genLExpr"
genLExpr (LILit     n   pt     ) = pure $ mkConst pt n
genLExpr (LSLit     s          ) = __todo "genLExpr"
genLExpr (LLet      a e1 e2    ) = __todo "genLExpr"
genLExpr (LLetBang  vs a e1 e2 ) = __todo "genLExpr"
genLExpr (LTuple    e1 e2      ) = __todo "genLExpr"
genLExpr (LStruct   fs         ) = __todo "genLExpr"
genLExpr (LIf       c e1 e2    ) = __todo "genLExpr"
genLExpr (LCase     c tag (l1,a1,e1) (l2,a2,e2)) = __todo "genLExpr"
genLExpr (LEsac     e          ) = __todo "genLExpr"
genLExpr (LSplit    a tp e     ) = __todo "genLExpr"
genLExpr (LMember   rec fld    ) = __todo "genLExpr"
genLExpr (LTake     a rec fld e) = __todo "genLExpr"
genLExpr (LPut      rec fld e  ) = __todo "genLExpr"
genLExpr (LPromote  ty e       ) = __todo "genLExpr"
genLExpr (LCast     ty e       ) = __todo "genLExpr"


