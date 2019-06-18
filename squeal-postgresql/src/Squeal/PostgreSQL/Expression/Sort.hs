{-|
Module: Squeal.PostgreSQL.Expression.Sort
Description: Sort expressions
Copyright: (c) Eitan Chatav, 2019
Maintainer: eitan@morphism.tech
Stability: experimental

Sort expressions
-}

{-# LANGUAGE
    DataKinds
  , GADTs
  , LambdaCase
  , OverloadedStrings
  , StandaloneDeriving
#-}

module Squeal.PostgreSQL.Expression.Sort
  ( SortExpression (..)
  , OrderBy (..)
  ) where

import Squeal.PostgreSQL.Expression
import Squeal.PostgreSQL.Render
import Squeal.PostgreSQL.Schema

-- | `SortExpression`s are used by `orderBy` to optionally sort the results
-- of a `Squeal.PostgreSQL.Query.Query`. `Asc` or `Desc`
-- set the sort direction of a `NotNull` result
-- column to ascending or descending. Ascending order puts smaller values
-- first, where "smaller" is defined in terms of the
-- `Squeal.PostgreSQL.Expression.Comparison..<` operator. Similarly,
-- descending order is determined with the
-- `Squeal.PostgreSQL.Expression.Comparison..>` operator. `AscNullsFirst`,
-- `AscNullsLast`, `DescNullsFirst` and `DescNullsLast` options are used to
-- determine whether nulls appear before or after non-null values in the sort
-- ordering of a `Null` result column.
data SortExpression outer commons grp schemas params from where
  Asc
    :: Expression outer commons grp schemas params from ('NotNull ty)
    -> SortExpression outer commons grp schemas params from
  Desc
    :: Expression outer commons grp schemas params from ('NotNull ty)
    -> SortExpression outer commons grp schemas params from
  AscNullsFirst
    :: Expression outer commons grp schemas params from  ('Null ty)
    -> SortExpression outer commons grp schemas params from
  AscNullsLast
    :: Expression outer commons grp schemas params from  ('Null ty)
    -> SortExpression outer commons grp schemas params from
  DescNullsFirst
    :: Expression outer commons grp schemas params from  ('Null ty)
    -> SortExpression outer commons grp schemas params from
  DescNullsLast
    :: Expression outer commons grp schemas params from  ('Null ty)
    -> SortExpression outer commons grp schemas params from
deriving instance Show (SortExpression outer commons grp schemas params from)
instance RenderSQL (SortExpression outer commons grp schemas params from) where
  renderSQL = \case
    Asc expression -> renderSQL expression <+> "ASC"
    Desc expression -> renderSQL expression <+> "DESC"
    AscNullsFirst expression -> renderSQL expression
      <+> "ASC NULLS FIRST"
    DescNullsFirst expression -> renderSQL expression
      <+> "DESC NULLS FIRST"
    AscNullsLast expression -> renderSQL expression <+> "ASC NULLS LAST"
    DescNullsLast expression -> renderSQL expression <+> "DESC NULLS LAST"

{- |
The `orderBy` clause causes the result rows of a `Squeal.PostgreSQL.Query.TableExpression`
to be sorted according to the specified `SortExpression`(s).
If two rows are equal according to the leftmost expression,
they are compared according to the next expression and so on.
If they are equal according to all specified expressions,
they are returned in an implementation-dependent order.

You can also control the order in which rows are processed by window functions
using `orderBy` within `Squeal.PostgreSQL.Query.Over`.
-}
class OrderBy expr where
  orderBy
    :: [SortExpression outer commons grp schemas params from]
    -> expr outer commons grp schemas params from
    -> expr outer commons grp schemas params from
