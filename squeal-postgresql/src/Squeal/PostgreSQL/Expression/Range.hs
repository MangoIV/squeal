{-|
Module: Squeal.PostgreSQL.Expression.Range
Description: range types and functions
Copyright: (c) Eitan Chatav, 2019
Maintainer: eitan@morphism.tech
Stability: experimental

Range types and functions
-}

{-# LANGUAGE
    AllowAmbiguousTypes
  , DataKinds
  , DeriveAnyClass
  , DeriveGeneric
  , DeriveFoldable
  , DerivingStrategies
  , DeriveTraversable
  , FlexibleContexts
  , FlexibleInstances
  , LambdaCase
  , MultiParamTypeClasses
  , OverloadedLabels
  , OverloadedStrings
  , PatternSynonyms
  , RankNTypes
  , ScopedTypeVariables
  , TypeApplications
  , TypeFamilies
  , TypeOperators
  , UndecidableInstances
#-}

module Squeal.PostgreSQL.Expression.Range
  ( range
  , Range (..)
  , (<=..<=), (<..<), (<=..<), (<..<=)
  , pattern HalfGT, pattern HalfGTE
  , pattern HalfLT, pattern HalfLTE
  , Bound (..)
  , pattern Closed, pattern Open
  ) where

import Data.Bool

import qualified GHC.Generics as GHC
import qualified Generics.SOP as SOP

import Squeal.PostgreSQL.Expression
import Squeal.PostgreSQL.PG
import Squeal.PostgreSQL.Render
import Squeal.PostgreSQL.Schema

-- $setup
-- >>> import Squeal.PostgreSQL

-- | >>> printSQL $ range (HalfGTE now)
-- [now(), )
-- >>> printSQL $ range (0 <..<= (pi & astype numeric))
-- (0, (pi() :: numeric)]
range
  :: Range (Expression outer commons grp schemas params from ('NotNull ty))
  -> Expression outer commons grp schemas params from (null ('PGrange ty))
range = UnsafeExpression . renderSQL

data Bound x = Bound
  { closedBound :: Bool
  , getBound :: Maybe x
  } deriving
    ( Eq, Ord, Show, Read, GHC.Generic
    , Functor, Foldable, Traversable )
    deriving anyclass (SOP.Generic, SOP.HasDatatypeInfo)
pattern Closed, Open :: Maybe x -> Bound x
pattern Closed x = Bound True x
pattern Open x = Bound False x

data Range x
  = Empty
  | NonEmpty (Bound x) (Bound x)
  deriving
    ( Eq, Ord, Show, Read, GHC.Generic
    , Functor, Foldable, Traversable )
  deriving anyclass (SOP.Generic, SOP.HasDatatypeInfo)
type instance PG (Range x) = 'PGrange (PG x)

instance RenderSQL x => RenderSQL (Range x) where
  renderSQL = \case
    Empty -> "empty"
    NonEmpty l u -> commaSeparated [renderLower l, renderUpper u]
      where
        renderLower (Bound isClosed x) =
          bool "(" "[" isClosed <> maybe "" renderSQL x
        renderUpper (Bound isClosed x) =
          maybe "" renderSQL x <> bool ")" "]" isClosed

(<=..<=), (<..<), (<=..<), (<..<=) :: x -> x -> Range x
x <=..<= y = NonEmpty (Closed (Just x)) (Closed (Just y))
x <..< y = NonEmpty (Open (Just x)) (Open (Just y))
x <=..< y = NonEmpty (Closed (Just x)) (Open (Just y))
x <..<= y = NonEmpty (Open (Just x)) (Closed (Just y))

pattern HalfGT, HalfGTE, HalfLT, HalfLTE :: x -> Range x
pattern HalfGT x = NonEmpty (Open (Just x)) (Open Nothing)
pattern HalfGTE x = NonEmpty (Closed (Just x)) (Open Nothing)
pattern HalfLT x = NonEmpty (Open Nothing) (Open (Just x))
pattern HalfLTE x = NonEmpty (Open Nothing) (Closed (Just x))
