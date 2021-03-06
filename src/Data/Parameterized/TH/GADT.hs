------------------------------------------------------------------------
-- |
-- Module           : Data.Parameterized.TH.GADT
-- Copyright        : (c) Galois, Inc 2013-2019
-- Maintainer       : Joe Hendrix <jhendrix@galois.com>
-- Description : Template Haskell primitives for working with large GADTs
--
-- This module declares template Haskell primitives so that it is easier
-- to work with GADTs that have many constructors.
------------------------------------------------------------------------
{-# LANGUAGE DoAndIfThenElse #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE TemplateHaskell #-}
{-# LANGUAGE TypeOperators #-}
{-# LANGUAGE EmptyCase #-}
module Data.Parameterized.TH.GADT
  ( -- * Instance generators
    -- $typePatterns
  structuralEquality
  , structuralTypeEquality
  , structuralTypeOrd
  , structuralTraversal
  , structuralShowsPrec
  , structuralHash
  , structuralHashWithSalt
  , PolyEq(..)
    -- * Template haskell utilities that may be useful in other contexts.
  , DataD
  , lookupDataType'
  , asTypeCon
  , conPat
  , TypePat(..)
  , dataParamTypes
  , assocTypePats
  ) where

import Control.Monad
import Data.Maybe
import Data.Set (Set)
import qualified Data.Set as Set
import Language.Haskell.TH
import Language.Haskell.TH.Datatype


import Data.Parameterized.Classes

------------------------------------------------------------------------
-- Template Haskell utilities

type DataD = DatatypeInfo

lookupDataType' :: Name -> Q DatatypeInfo
lookupDataType' = reifyDatatype

-- | Given a constructor and string, this generates a pattern for matching
-- the expression, and the names of variables bound by pattern in order
-- they appear in constructor.
conPat ::
  ConstructorInfo {- ^ constructor information -} ->
  String          {- ^ generated name prefix   -} ->
  Q (Pat, [Name]) {- ^ pattern and bound names -}
conPat con pre = do
  nms <- newNames pre (length (constructorFields con))
  return (ConP (constructorName con) (VarP <$> nms), nms)


-- | Return an expression corresponding to the constructor.
-- Note that this will have the type of a function expecting
-- the argumetns given.
conExpr :: ConstructorInfo -> Exp
conExpr = ConE . constructorName

------------------------------------------------------------------------
-- TypePat

-- | A type used to describe (and match) types appearing in generated pattern
-- matches inside of the TH generators in this module ('structuralEquality',
-- 'structuralTypeEquality', 'structuralTypeOrd', and 'structuralTraversal')
data TypePat
   = TypeApp TypePat TypePat -- ^ The application of a type.
   | AnyType       -- ^ Match any type.
   | DataArg Int   -- ^ Match the i'th argument of the data type we are traversing.
   | ConType TypeQ -- ^ Match a ground type.

matchTypePat :: [Type] -> TypePat -> Type -> Q Bool
matchTypePat d (TypeApp p q) (AppT x y) = do
  r <- matchTypePat d p x
  case r of
    True -> matchTypePat d q y
    False -> return False
matchTypePat _ AnyType _ = return True
matchTypePat tps (DataArg i) tp
  | i < 0 || i >= length tps = error ("Type pattern index " ++ show i ++ " out of bounds")
  | otherwise = return (stripSigT (tps !! i) == tp)
  where
    -- th-abstraction can annotate type parameters with their kinds,
    -- we ignore these for matching
    stripSigT (SigT t _) = t
    stripSigT t          = t
matchTypePat _ (ConType tpq) tp = do
  tp' <- tpq
  return (tp' == tp)
matchTypePat _ _ _ = return False

-- | The dataParamTypes function returns the list of Type arguments
-- for the constructor.  For example, if passed the DatatypeInfo for a
-- @newtype Id a = MkId a@ then this would return @['SigT' ('VarT' a)
-- 'StarT']@.  Note that there may be type *variables* not referenced
-- in the returned array; this simply returns the type *arguments*.
dataParamTypes :: DatatypeInfo -> [Type]
dataParamTypes = datatypeInstTypes
 -- see th-abstraction 'dataTypeVars' for the type variables if needed

-- | Find value associated with first pattern that matches given pat if any.
assocTypePats :: [Type] -> [(TypePat, v)] -> Type -> Q (Maybe v)
assocTypePats _ [] _ = return Nothing
assocTypePats dTypes ((p,v):pats) tp = do
  r <- matchTypePat dTypes p tp
  case r of
    True -> return (Just v)
    False -> assocTypePats dTypes pats tp

------------------------------------------------------------------------
-- Contructor cases

typeVars :: TypeSubstitution a => a -> Set Name
typeVars = Set.fromList . freeVariables


-- | @structuralEquality@ declares a structural equality predicate.
structuralEquality :: TypeQ -> [(TypePat,ExpQ)] -> ExpQ
structuralEquality tpq pats =
  [| \x y -> isJust ($(structuralTypeEquality tpq pats) x y) |]

joinEqMaybe :: Name -> Name -> ExpQ -> ExpQ
joinEqMaybe x y r = do
  [| if $(varE x) == $(varE y) then $(r) else Nothing |]

joinTestEquality :: ExpQ -> Name -> Name -> ExpQ -> ExpQ
joinTestEquality f x y r =
  [| case $(f) $(varE x) $(varE y) of
      Nothing -> Nothing
      Just Refl -> $(r)
   |]

matchEqArguments :: [Type]
                    -- ^ Types bound by data arguments.
                 -> [(TypePat,ExpQ)] -- ^ Patterns for matching arguments
                 -> Name
                     -- ^ Name of constructor.
                 -> Set Name
                 -> [Type]
                 -> [Name]
                 -> [Name]
                 -> ExpQ
matchEqArguments dTypes pats cnm bnd (tp:tpl) (x:xl) (y:yl) = do
  doesMatch <- assocTypePats dTypes pats tp
  case doesMatch of
    Just q -> do
      let bnd' =
            case tp of
              AppT _ (VarT nm) -> Set.insert nm bnd
              _ -> bnd
      joinTestEquality q x y (matchEqArguments dTypes pats cnm bnd' tpl xl yl)
    Nothing | typeVars tp `Set.isSubsetOf` bnd -> do
      joinEqMaybe x y        (matchEqArguments dTypes pats cnm bnd  tpl xl yl)
    Nothing -> do
      fail $ "Unsupported argument type " ++ show tp
          ++ " in " ++ show (ppr cnm) ++ "."
matchEqArguments _ _ _ _ [] [] [] = [| Just Refl |]
matchEqArguments _ _ _ _ [] _  _  = error "Unexpected end of types."
matchEqArguments _ _ _ _ _  [] _  = error "Unexpected end of names."
matchEqArguments _ _ _ _ _  _  [] = error "Unexpected end of names."

mkSimpleEqF :: [Type] -- ^ Data declaration types
            -> Set Name
             -> [(TypePat,ExpQ)] -- ^ Patterns for matching arguments
             -> ConstructorInfo
             -> [Name]
             -> ExpQ
             -> Bool -- ^ wildcard case required
             -> ExpQ
mkSimpleEqF dTypes bnd pats con xv yQ multipleCases = do
  -- Get argument types for constructor.
  let nm = constructorName con
  (yp,yv) <- conPat con "y"
  let rv = matchEqArguments dTypes pats nm bnd (constructorFields con) xv yv
  caseE yQ $ match (pure yp) (normalB rv) []
           : [ match wildP (normalB [| Nothing |]) [] | multipleCases ]

-- | Match equational form.
mkEqF :: DatatypeInfo -- ^ Data declaration.
      -> [(TypePat,ExpQ)]
      -> ConstructorInfo
      -> [Name]
      -> ExpQ
      -> Bool -- ^ wildcard case required
      -> ExpQ
mkEqF d pats con =
  let dVars = dataParamTypes d  -- the type arguments for the constructor
      -- bnd is the list of type arguments for this datatype.  Since
      -- this is Functor equality, ignore the final type since this is
      -- a higher-kinded equality.
      bnd | null dVars = Set.empty
          | otherwise  = typeVars (init dVars)
  in mkSimpleEqF dVars bnd pats con

-- | @structuralTypeEquality f@ returns a function with the type:
--   @
--     forall x y . f x -> f y -> Maybe (x :~: y)
--   @
structuralTypeEquality :: TypeQ -> [(TypePat,ExpQ)] -> ExpQ
structuralTypeEquality tpq pats = do
  d <- reifyDatatype =<< asTypeCon "structuralTypeEquality" =<< tpq

  let multipleCons = not (null (drop 1 (datatypeCons d)))
      trueEqs yQ = [ do (xp,xv) <- conPat con "x"
                        match (pure xp) (normalB (mkEqF d pats con xv yQ multipleCons)) []
                   | con <- datatypeCons d
                   ]

  if null (datatypeCons d)
    then [| \x -> case x of {} |]
    else [| \x y -> $(caseE [| x |] (trueEqs [| y |])) |]

-- | @structuralTypeOrd f@ returns a function with the type:
--   @
--     forall x y . f x -> f y -> OrderingF x y
--   @
--
-- This implementation avoids matching on both the first and second
-- parameters in a simple case expression in order to avoid stressing
-- GHC's coverage checker. In the case that the first and second parameters
-- have unique constructors, a simple numeric comparison is done to
-- compute the result.
structuralTypeOrd ::
  TypeQ ->
  [(TypePat,ExpQ)] {- ^ List of type patterns to match. -} ->
  ExpQ
structuralTypeOrd tpq l = do
  d <- reifyDatatype =<< asTypeCon "structuralTypeEquality" =<< tpq

  let withNumber :: ExpQ -> (Maybe ExpQ -> ExpQ) -> ExpQ
      withNumber yQ k
        | null (drop 1 (datatypeCons d)) = k Nothing
        | otherwise =  [| let yn :: Int
                              yn = $(caseE yQ (constructorNumberMatches (datatypeCons d)))
                          in $(k (Just [| yn |])) |]

  if null (datatypeCons d)
    then [| \x -> case x of {} |]
    else [| \x y -> $(withNumber [|y|] $ \mbYn -> caseE [| x |] (outerOrdMatches d [|y|] mbYn)) |]
  where
    constructorNumberMatches :: [ConstructorInfo] -> [MatchQ]
    constructorNumberMatches cons =
      [ match (recP (constructorName con) [])
              (normalB (litE (integerL i)))
              []
      | (i,con) <- zip [0..] cons ]

    outerOrdMatches :: DatatypeInfo -> ExpQ -> Maybe ExpQ -> [MatchQ]
    outerOrdMatches d yExp mbYn =
      [ do (pat,xv) <- conPat con "x"
           match (pure pat)
                 (normalB (do xs <- mkOrdF d l con i mbYn xv
                              caseE yExp xs))
                 []
      | (i,con) <- zip [0..] (datatypeCons d) ]

-- | Generate a list of fresh names using the base name
-- and numbered 1 to @n@ to make them useful in conjunction with
-- @-dsuppress-uniques@.
newNames ::
  String   {- ^ base name                     -} ->
  Int      {- ^ quantity                      -} ->
  Q [Name] {- ^ list of names: @base1@, @base2@, ... -}
newNames base n = traverse (\i -> newName (base ++ show i)) [1..n]


joinCompareF :: ExpQ -> Name -> Name -> ExpQ -> ExpQ
joinCompareF f x y r = do
  [| case $(f) $(varE x) $(varE y) of
      LTF -> LTF
      GTF -> GTF
      EQF -> $(r)
   |]

-- | Compare two variables, returning the third argument if they are equal.
--
-- This returns an 'OrdF' instance.
joinCompareToOrdF :: Name -> Name -> ExpQ -> ExpQ
joinCompareToOrdF x y r =
  [| case compare $(varE x) $(varE y) of
      LT -> LTF
      GT -> GTF
      EQ -> $(r)
   |]

-- | Match expression with given type to variables
matchOrdArguments :: [Type]
                     -- ^ Types bound by data arguments
                  -> [(TypePat,ExpQ)] -- ^ Patterns for matching arguments
                  -> Name
                     -- ^ Name of constructor.
                  -> Set Name
                    -- ^ Names bound in data declaration
                  -> [Type]
                     -- ^ Types for constructors
                  -> [Name]
                     -- ^ Variables bound in first pattern
                  -> [Name]
                     -- ^ Variables bound in second pattern
                  -> ExpQ
matchOrdArguments dTypes pats cnm bnd (tp : tpl) (x:xl) (y:yl) = do
  doesMatch <- assocTypePats dTypes pats tp
  case doesMatch of
    Just f -> do
      let bnd' = case tp of
                   AppT _ (VarT nm) -> Set.insert nm bnd
                   _ -> bnd
      joinCompareF f x y (matchOrdArguments dTypes pats cnm bnd' tpl xl yl)
    Nothing | typeVars tp `Set.isSubsetOf` bnd -> do
      joinCompareToOrdF x y (matchOrdArguments dTypes pats cnm bnd tpl xl yl)
    Nothing ->
      fail $ "Unsupported argument type " ++ show (ppr tp)
             ++ " in " ++ show (ppr cnm) ++ "."
matchOrdArguments _ _ _ _ [] [] [] = [| EQF |]
matchOrdArguments _ _ _ _ [] _  _  = error "Unexpected end of types."
matchOrdArguments _ _ _ _ _  [] _  = error "Unexpected end of names."
matchOrdArguments _ _ _ _ _  _  [] = error "Unexpected end of names."

mkSimpleOrdF :: [Type] -- ^ Data declaration types
             -> [(TypePat,ExpQ)] -- ^ Patterns for matching arguments
             -> ConstructorInfo -- ^ Information about the second constructor
             -> Integer -- ^ First constructor's index
             -> Maybe ExpQ -- ^ Optional second constructor's index
             -> [Name]  -- ^ Name from first pattern
             -> Q [MatchQ]
mkSimpleOrdF dTypes pats con xnum mbYn xv = do
  (yp,yv) <- conPat con "y"
  let rv = matchOrdArguments dTypes pats (constructorName con) Set.empty (constructorFields con) xv yv
  -- Return match expression
  return $ match (pure yp) (normalB rv) []
         : case mbYn of
             Nothing -> []
             Just yn -> [match wildP (normalB [| if xnum < $yn then LTF else GTF |]) []]

-- | Match equational form.
mkOrdF :: DatatypeInfo -- ^ Data declaration.
       -> [(TypePat,ExpQ)] -- ^ Patterns for matching arguments
       -> ConstructorInfo
       -> Integer
       -> Maybe ExpQ -- ^ optional right constructr index
       -> [Name]
       -> Q [MatchQ]
mkOrdF d pats = mkSimpleOrdF (datatypeInstTypes d) pats

-- | @genTraverseOfType f var tp@ applies @f@ to @var@ where @var@ has type @tp@.
genTraverseOfType :: [Type]
                    -- ^ Argument types for the data declaration.
                 -> [(TypePat, ExpQ)]
                    -- ^ Patterrns the user provided for overriding type lookup.
                  -> ExpQ -- ^ Function to apply
                  -> ExpQ -- ^ Expression denoting value of this constructor field.
                  -> Type -- ^ Type bound for this constructor field.
                  -> Q (Maybe Exp)
genTraverseOfType dataArgs pats f v tp = do
  mr <- assocTypePats dataArgs pats tp
  case mr of
    Just g ->  Just <$> [| $(g) $(f) $(v) |]
    Nothing ->
      case tp of
        AppT (ConT _) (AppT (VarT _) _) -> Just <$> [| traverse $(f) $(v) |]
        AppT (VarT _) _ -> Just <$> [| $(f) $(v) |]
        _ -> return Nothing

-- | @traverseAppMatch patMatch cexp @ builds a case statement that matches a term with
-- the constructor @c@ and applies @f@ to each argument.
traverseAppMatch :: [Type]
                    -- ^ Argument types for the data declaration.
                 -> [(TypePat, ExpQ)]
                    -- ^ Patterrns the user provided for overriding type lookup.
                 -> ExpQ -- ^ Function @f@ given to `traverse`
                 -> ConstructorInfo -- ^ Constructor to match.
                 -> MatchQ
traverseAppMatch dataArgs pats fv c0 = do
  (pat,patArgs) <- conPat c0 "p"
  exprs <- zipWithM (genTraverseOfType dataArgs pats fv) (varE <$> patArgs) (constructorFields c0)
  let mkRes :: ExpQ -> [(Name, Maybe Exp)] -> ExpQ
      mkRes e [] = e
      mkRes e ((v,Nothing):r) =
        mkRes (appE e (varE v)) r
      mkRes e ((_,Just{}):r) = do
        v <- newName "r"
        lamE [varP v] (mkRes (appE e (varE v)) r)

  -- Apply the remaining argument to the expression in list.
  let applyRest :: ExpQ -> [Exp] -> ExpQ
      applyRest e [] = e
      applyRest e (a:r) = applyRest [| $(e) <*> $(pure a) |] r

  -- Apply the first argument to the list
  let applyFirst :: ExpQ -> [Exp] -> ExpQ
      applyFirst e [] = [| pure $(e) |]
      applyFirst e (a:r) = applyRest [| $(e) <$> $(pure a) |] r

  let pargs = patArgs `zip` exprs
  let rhs = applyFirst (mkRes (pure (conExpr c0)) pargs) (catMaybes exprs)
  match (pure pat) (normalB rhs) []

-- | @structuralTraversal tp@ generates a function that applies
-- a traversal @f@ to the subterms with free variables in @tp@.
structuralTraversal :: TypeQ -> [(TypePat, ExpQ)] -> ExpQ
structuralTraversal tpq pats0 = do
  d <- reifyDatatype =<< asTypeCon "structuralTraversal" =<< tpq
  f <- newName "f"
  a <- newName "a"
  lamE [varP f, varP a] $
      caseE (varE a)
      (traverseAppMatch (datatypeInstTypes d) pats0 (varE f) <$> datatypeCons d)

asTypeCon :: String -> Type -> Q Name
asTypeCon _ (ConT nm) = return nm
asTypeCon fn _ = fail (fn ++ " expected type constructor.")

-- | @structuralHash tp@ generates a function with the type
-- @Int -> tp -> Int@ that hashes type.
--
-- All arguments use `hashable`, and `structuralHashWithSalt` can be
-- used instead as it allows user-definable patterns to be used at
-- specific types.
structuralHash :: TypeQ -> ExpQ
structuralHash tpq = structuralHashWithSalt tpq []
{-# DEPRECATED structuralHash "Use structuralHashWithSalt" #-}

-- | @structuralHashWithSalt tp@ generates a function with the type
-- @Int -> tp -> Int@ that hashes type.
--
-- The second arguments is for generating user-defined patterns to replace
-- `hashWithSalt` for specific types.
structuralHashWithSalt :: TypeQ -> [(TypePat, ExpQ)] -> ExpQ
structuralHashWithSalt tpq pats = do
  d <- reifyDatatype =<< asTypeCon "structuralHash" =<< tpq
  s <- newName "s"
  a <- newName "a"
  lamE [varP s, varP a] $
    caseE (varE a) (zipWith (matchHashCtor d pats (varE s)) [0..] (datatypeCons d))

-- | This matches one of the constructors in a datatype when generating
-- a `hashWithSalt` function.
matchHashCtor :: DatatypeInfo
                 -- ^ Data declaration of type we are hashing.
              -> [(TypePat, ExpQ)]
                 -- ^ User provide type patterns
              -> ExpQ -- ^ Initial salt expression
              -> Integer -- ^ Index of constructor
              -> ConstructorInfo -- ^ Constructor information
              -> MatchQ
matchHashCtor d pats s0 i c = do
  (pat,vars) <- conPat c "x"
  let go s (e, tp) = do
        mr <- assocTypePats (datatypeInstTypes d) pats tp
        case mr of
          Just f -> do
            [| $(f) $(s) $(e) |]
          Nothing ->
            [| hashWithSalt $(s) $(e) |]
  let s1 = [| hashWithSalt $(s0) ($(litE (IntegerL i)) :: Int) |]
  let rhs = foldl go s1 (zip (varE <$> vars) (constructorFields c))
  match (pure pat) (normalB rhs) []

-- | @structuralShow tp@ generates a function with the type
-- @tp -> ShowS@ that shows the constructor.
structuralShowsPrec :: TypeQ -> ExpQ
structuralShowsPrec tpq = do
  d <- reifyDatatype =<< asTypeCon "structuralShowPrec" =<< tpq
  p <- newName "_p"
  a <- newName "a"
  lamE [varP p, varP a] $
    caseE (varE a) (matchShowCtor (varE p) <$> datatypeCons d)

showCon :: ExpQ -> Name -> Int -> MatchQ
showCon p nm n = do
  vars <- newNames "x" n
  let pat = ConP nm (VarP <$> vars)
  let go s e = [| $(s) . showChar ' ' . showsPrec 11 $(varE e) |]
  let ctor = [| showString $(return (LitE (StringL (nameBase nm)))) |]
  let rhs | null vars = ctor
          | otherwise = [| showParen ($(p) >= 11) $(foldl go ctor vars) |]
  match (pure pat) (normalB rhs) []

matchShowCtor :: ExpQ -> ConstructorInfo -> MatchQ
matchShowCtor p con = showCon p (constructorName con) (length (constructorFields con))

-- $typePatterns
--
-- The Template Haskell instance generators 'structuralEquality',
-- 'structuralTypeEquality', 'structuralTypeOrd', and 'structuralTraversal'
-- employ heuristics to generate valid instances in the majority of cases.  Most
-- failures in the heuristics occur on sub-terms that are type indexed.  To
-- handle cases where these functions fail to produce a valid instance, they
-- take a list of exceptions in the form of their second parameter, which has
-- type @[('TypePat', 'ExpQ')]@.  Each 'TypePat' is a /matcher/ that tells the
-- TH generator to use the 'ExpQ' to process the matched sub-term.  Consider the
-- following example:
--
-- > data T a b where
-- >   C1 :: NatRepr n -> T () n
-- >
-- > instance TestEquality (T a) where
-- >   testEquality = $(structuralTypeEquality [t|T|]
-- >                    [ (ConType [t|NatRepr|] `TypeApp` AnyType, [|testEquality|])
-- >                    ])
--
-- The exception list says that 'structuralTypeEquality' should use
-- 'testEquality' to compare any sub-terms of type @'NatRepr' n@ in a value of
-- type @T@.
--
-- * 'AnyType' means that the type parameter in that position can be instantiated as any type
--
-- * @'DataArg' n@ means that the type parameter in that position is the @n@-th
--   type parameter of the GADT being traversed (@T@ in the example)
--
-- * 'TypeApp' is type application
--
-- * 'ConType' specifies a base type
--
-- The exception list could have equivalently (and more precisely) have been specified as:
--
-- > [(ConType [t|NatRepr|] `TypeApp` DataArg 1, [|testEquality|])]
--
-- The use of 'DataArg' says that the type parameter of the 'NatRepr' must
-- be the same as the second type parameter of @T@.
