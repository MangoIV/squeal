{-|
Module: Squeal.PostgreSQL.Migration
Description: Squeal migrations
Copyright: (c) Eitan Chatav, 2017
Maintainer: eitan@morphism.tech
Stability: experimental

This module defines a `Migration` type to safely
change the schema of your database over time. Let's see an example!

First turn on some extensions.

>>> :set -XDataKinds -XOverloadedLabels
>>> :set -XOverloadedStrings -XFlexibleContexts -XTypeOperators

Next, let's define our `TableType`s.

>>> :{
type UsersTable =
  '[ "pk_users" ::: 'PrimaryKey '["id"] ] :=>
  '[ "id" ::: 'Def :=> 'NotNull 'PGint4
   , "name" ::: 'NoDef :=> 'NotNull 'PGtext
   ]
:}

>>> :{
type EmailsTable =
  '[ "pk_emails" ::: 'PrimaryKey '["id"]
   , "fk_user_id" ::: 'ForeignKey '["user_id"] "users" '["id"]
   ] :=>
  '[ "id" ::: 'Def :=> 'NotNull 'PGint4
   , "user_id" ::: 'NoDef :=> 'NotNull 'PGint4
   , "email" ::: 'NoDef :=> 'Null 'PGtext
   ]
:}

Now we can define some `Migration`s to make our tables.

>>> :{
let
  makeUsers :: Migration (IsoQ Definition) (Public '[]) '["public" ::: '["users" ::: 'Table UsersTable]]
  makeUsers = Migration "make users table" IsoQ
    { up = createTable #users
        ( serial `as` #id :*
          notNullable text `as` #name )
        ( primaryKey #id `as` #pk_users )
    , down = dropTable #users
    }
:}

>>> :{
let
  makeEmails :: Migration (IsoQ Definition) '["public" ::: '["users" ::: 'Table UsersTable]]
    '["public" ::: '["users" ::: 'Table UsersTable, "emails" ::: 'Table EmailsTable]]
  makeEmails = Migration "make emails table" IsoQ
    { up = createTable #emails
          ( serial `as` #id :*
            notNullable int `as` #user_id :*
            nullable text `as` #email )
          ( primaryKey #id `as` #pk_emails :*
            foreignKey #user_id #users #id
              OnDeleteCascade OnUpdateCascade `as` #fk_user_id )
    , down = dropTable #emails
    }
:}

Now that we have a couple migrations we can chain them together into a `Path`.

>>> let migrations = makeUsers :>> makeEmails :>> Done

Now run the migrations.

>>> import Control.Monad.IO.Class
>>> :{
withConnection "host=localhost port=5432 dbname=exampledb" $
  manipulate (UnsafeManipulation "SET client_min_messages TO WARNING;")
    -- suppress notices
  & pqThen (liftIO (putStrLn "Migrate"))
  & pqThen (migrateUp migrations)
  & pqThen (liftIO (putStrLn "Rollback"))
  & pqThen (migrateDown migrations)
:}
Migrate
Rollback

We can also create a simple executable using `mainMigrateIso`.

>>> let main = mainMigrateIso "host=localhost port=5432 dbname=exampledb" migrations

>>> withArgs [] main
Invalid command: "". Use:
migrate    to run all available migrations
rollback   to rollback all available migrations
status     to display migrations run and migrations left to run

>>> withArgs ["status"] main
Migrations already run:
  None
Migrations left to run:
  - make users table
  - make emails table

>>> withArgs ["migrate"] main
Migrations already run:
  - make users table
  - make emails table
Migrations left to run:
  None

>>> withArgs ["rollback"] main
Migrations already run:
  None
Migrations left to run:
  - make users table
  - make emails table

In addition to enabling `Migration`s using pure SQL `Definition`s for
the `up` and `down` instructions, you can also perform impure `IO` actions
by using a `Migration`s over the `Terminally` `PQ` `IO` category.
-}

{-# LANGUAGE
    DataKinds
  , DeriveGeneric
  , FlexibleContexts
  , FlexibleInstances
  , GADTs
  , LambdaCase
  , OverloadedLabels
  , OverloadedStrings
  , PolyKinds
  , QuantifiedConstraints
  , RankNTypes
  , TypeApplications
  , TypeOperators
#-}

module Squeal.PostgreSQL.Migration
  ( -- * Migration
    Migration (..)
  , Migratory (..)
  , Terminally (..)
  , IsoQ (..)
  , terminally
  , pureMigration
  , pureMigrationIso
  , MigrationsTable
  , mainMigrate
  , mainMigrateIso
  ) where

import Control.Category
import Control.Category.Free
import Control.Monad
import Data.ByteString (ByteString)
import Data.Foldable (traverse_)
import Data.Function ((&))
import Data.List ((\\))
import Data.Quiver
import Data.Quiver.Functor
import Data.Text (Text)
import Data.Time (UTCTime)
import Prelude hiding ((.), id)
import System.Environment
import UnliftIO (MonadIO (..))

import qualified Data.Text.IO as Text (putStrLn)
import qualified Generics.SOP as SOP
import qualified GHC.Generics as GHC

import Squeal.PostgreSQL.Alias
import Squeal.PostgreSQL.Binary
import Squeal.PostgreSQL.Definition
import Squeal.PostgreSQL.Definition.Table
import Squeal.PostgreSQL.Definition.Table.Column
import Squeal.PostgreSQL.Definition.Table.Constraint
import Squeal.PostgreSQL.Expression.Comparison
import Squeal.PostgreSQL.Expression.Parameter
import Squeal.PostgreSQL.Expression.Time
import Squeal.PostgreSQL.Expression.Type
import Squeal.PostgreSQL.List
import Squeal.PostgreSQL.Manipulation
import Squeal.PostgreSQL.PQ
import Squeal.PostgreSQL.Query
import Squeal.PostgreSQL.Schema
import Squeal.PostgreSQL.Transaction

-- | A `Migration` is a named "isomorphism" over a given category.
-- It should contain an inverse pair of `up` and `down`
-- instructions and a unique `name`.
data Migration p schemas0 schemas1 = Migration
  { name :: Text -- ^ The `name` of a `Migration`.
    -- Each `name` in a `Migration` should be unique.
  , instruction :: p schemas0 schemas1 -- ^ The instruction of a `Migration`.
  } deriving (GHC.Generic)
instance CFunctor Migration where
  cmap f (Migration n i) = Migration n (f i)

{- |
A `Migratory` @p@ is a `Category` for which one can execute or rewind
a `Path` of `Migration`s over @p@. This includes the category of pure
SQL `Definition`s and the category of impure `Terminally` `PQ` `IO` actions.
-}
class Category p => Migratory p where

  migrate
    :: Path (Migration p) schemas0 schemas1
    -> PQ schemas0 schemas1 IO ()

  {- |
  Run a `Path` of `Migration`s.
  Create the `MigrationsTable` as @public.schema_migrations@ if it does not already exist.
  In one transaction, for each each `Migration` query to see if the `Migration` has been executed;
  if not, `up` the `Migration` and insert its `name` in the `MigrationsTable`.
  -}
  migrateUp
    :: Path (Migration (IsoQ p)) schemas0 schemas1
    -> PQ schemas0 schemas1 IO ()

  {- |
  Rewind a `Path` of `Migration`s.
  Create the `MigrationsTable` as @public.schema_migrations@ if it does not already exist.
  In one transaction, for each each `Migration` query to see if the `Migration` has been executed;
  if so, `down` the `Migration` and delete its `name` in the `MigrationsTable`.
  -}
  migrateDown
    :: Path (Migration (IsoQ p)) schemas0 schemas1
    -> PQ schemas1 schemas0 IO ()

instance Migratory Definition where
  migrate = migrate . cmap pureMigration
  migrateUp = migrateUp . cmap pureMigrationIso
  migrateDown = migrateDown . cmap pureMigrationIso

{- | `Terminally` turns an indexed monad transformer and the monad it transforms
into a category by restricting the return type to @()@ and permuting the type variables.
This is similar to how applying a monad to @()@ yields a monoid.
Since a `Terminally` action has a trivial return value, the only reason
to run one is for the side effects, in particular database and other IO effects.
-}
newtype Terminally trans monad x0 x1 = Terminally
  { runTerminally :: trans x0 x1 monad () }
  deriving GHC.Generic

instance
  ( IndexedMonadTransPQ trans
  , Monad monad
  , forall x0 x1. x0 ~ x1 => Monad (trans x0 x1 monad) )
  => Category (Terminally trans monad) where
    id = Terminally (return ())
    Terminally g . Terminally f = Terminally $ pqThen g f

-- | `terminally` ignores the output of a computation, returning @()@ and
-- wrapping it up into a `Terminally`. You can lift an action in the base monad
-- by using @terminally . lift@.
terminally
  :: Functor (trans x0 x1 monad)
  => trans x0 x1 monad ignore
  -> Terminally trans monad x0 x1
terminally = Terminally . void

-- | A `pureMigration` turns a `Migration` involving only pure SQL
-- `Definition`s into a `Migration` that may be combined with arbitrary `IO`.
pureMigration
  :: Migration Definition schemas0 schemas1
  -> Migration (Terminally PQ IO) schemas0 schemas1
pureMigration migration = Migration
  { name = name migration
  , instruction = terminally . define $ instruction migration
  }

-- | A `pureMigrationIso` turns a reversible `Migration`
-- involving only pure SQL
-- `Definition`s into a `Migration` that may be combined with arbitrary `IO`.
pureMigrationIso
  :: Migration (IsoQ Definition) schemas0 schemas1
  -> Migration (IsoQ (Terminally PQ IO)) schemas0 schemas1
pureMigrationIso migration = Migration
  { name = name migration
  , instruction = IsoQ
    { up = terminally . define . up $ instruction migration
    , down = terminally . define . down $ instruction migration
    }
  }

instance Migratory (Terminally PQ IO) where

  migrate migration = unsafePQ . transactionally_ $ do
    define createMigrations
    upMigrations migration

    where

      upMigrations
        :: Path (Migration (Terminally PQ IO)) schemas0 schemas1
        -> PQ MigrationsSchemas MigrationsSchemas IO ()
      upMigrations = \case
        Done -> return ()
        step :>> steps -> upMigration step >> upMigrations steps

      upMigration
        :: Migration (Terminally PQ IO) schemas0 schemas1
        -> PQ MigrationsSchemas MigrationsSchemas IO ()
      upMigration step = do
        executed <- queryExecuted step
        unless (executed == 1) $ do
          unsafePQ . runTerminally $ instruction step
          manipulateParams_ insertMigration (Only (name step))

      queryExecuted
        :: Migration (Terminally PQ IO) schemas0 schemas1
        -> PQ MigrationsSchemas MigrationsSchemas IO Row
      queryExecuted step = do
        result <- runQueryParams selectMigration (Only (name step))
        ntuples result

  migrateUp = migrate . cmap (cmap up)

  migrateDown migrations = unsafePQ . transactionally_ $ do
    define createMigrations
    downMigrations migrations

    where

      downMigrations
        :: Path (Migration (IsoQ (Terminally PQ IO))) schemas0 schemas1
        -> PQ MigrationsSchemas MigrationsSchemas IO ()
      downMigrations = \case
        Done -> return ()
        step :>> steps -> downMigrations steps >> downMigration step

      downMigration
        :: Migration (IsoQ (Terminally PQ IO)) schemas0 schemas1
        -> PQ MigrationsSchemas MigrationsSchemas IO ()
      downMigration step = do
        executed <- queryExecuted step
        unless (executed == 0) $ do
          unsafePQ . runTerminally . down $ instruction step
          manipulateParams_ deleteMigration (Only (name step))

      queryExecuted
        :: Migration (IsoQ (Terminally PQ IO)) schemas0 schemas1
        -> PQ MigrationsSchemas MigrationsSchemas IO Row
      queryExecuted step = do
        result <- runQueryParams selectMigration (Only (name step))
        ntuples result

unsafePQ :: (Functor m) => PQ db0 db1 m x -> PQ db0' db1' m x
unsafePQ (PQ pq) = PQ $ fmap (SOP.K . SOP.unK) . pq . SOP.K . SOP.unK

-- | The `TableType` for a Squeal migration.
type MigrationsTable =
  '[ "migrations_unique_name" ::: 'Unique '["name"]] :=>
  '[ "name"        ::: 'NoDef :=> 'NotNull 'PGtext
   , "executed_at" :::   'Def :=> 'NotNull 'PGtimestamptz
   ]

data MigrationRow =
  MigrationRow { migrationName :: Text
               , migrationTime :: UTCTime }
  deriving (GHC.Generic, Show)

instance SOP.Generic MigrationRow
instance SOP.HasDatatypeInfo MigrationRow

type MigrationsSchema = '["schema_migrations" ::: 'Table MigrationsTable]
type MigrationsSchemas = Public MigrationsSchema

-- | Creates a `MigrationsTable` if it does not already exist.
createMigrations :: Definition MigrationsSchemas MigrationsSchemas
createMigrations =
  createTableIfNotExists #schema_migrations
    ( (text & notNullable) `as` #name :*
      (timestampWithTimeZone & notNullable & default_ currentTimestamp)
        `as` #executed_at )
    ( unique #name `as` #migrations_unique_name )

-- | Inserts a `Migration` into the `MigrationsTable`, returning
-- the time at which it was inserted.
insertMigration :: Manipulation_ MigrationsSchemas (Only Text) ()
insertMigration = insertInto_ #schema_migrations
  (Values_ (Set (param @1) `as` #name :* Default `as` #executed_at))

-- | Deletes a `Migration` from the `MigrationsTable`, returning
-- the time at which it was inserted.
deleteMigration :: Manipulation_ MigrationsSchemas (Only Text) ()
deleteMigration = deleteFrom_ #schema_migrations (#name .== param @1)

-- | Selects a `Migration` from the `MigrationsTable`, returning
-- the time at which it was inserted.
selectMigration
  :: Query_ MigrationsSchemas (Only Text) (Only UTCTime)
selectMigration = select_ (#executed_at `as` #fromOnly)
  $ from (table (#schema_migrations))
  & where_ (#name .== param @1)

selectMigrations :: Query_ MigrationsSchemas () MigrationRow
selectMigrations = select_
  (#name `as` #migrationName :* #executed_at `as` #migrationTime)
  (from (table #schema_migrations))

data MigrateCommand = MigrateStatus | Migrate
  deriving (GHC.Generic, Show)

{- | `mainMigrate` creates a simple executable
from a connection string and a `Path` of `Migration`s. -}
mainMigrate
  :: Migratory p
  => ByteString
  -- ^ connection string
  -> Path (Migration p) db0 db1
  -- ^ migrations
  -> IO ()
mainMigrate connectTo migrations = do
  command <- readCommandFromArgs
  maybe (pure ()) performCommand command

  where

    performCommand :: MigrateCommand -> IO ()
    performCommand = \case
      MigrateStatus -> withConnection connectTo $
        suppressNotices >> migrateStatus
      Migrate -> withConnection connectTo $
        suppressNotices & pqThen (migrate migrations) & pqThen migrateStatus

    migrateStatus :: PQ schema schema IO ()
    migrateStatus = unsafePQ $ do
      runNames <- getRunMigrationNames
      let names = ctoList name migrations
          unrunNames = names \\ runNames
      liftIO $ displayRunned runNames >> displayUnrunned unrunNames

    suppressNotices :: PQ schema schema IO ()
    suppressNotices = manipulate_ $
      UnsafeManipulation "SET client_min_messages TO WARNING;"

    readCommandFromArgs :: IO (Maybe MigrateCommand)
    readCommandFromArgs = getArgs >>= \case
      ["migrate"] -> pure . Just $ Migrate
      ["status"] -> pure . Just $ MigrateStatus
      args -> displayUsage args >> pure Nothing

    displayUsage :: [String] -> IO ()
    displayUsage args = do
      putStrLn $ "Invalid command: \"" <> unwords args <> "\". Use:"
      putStrLn "migrate    to run all available migrations"
      putStrLn "rollback   to rollback all available migrations"

    getRunMigrationNames :: (MonadIO m) => PQ db0 db0 m [Text]
    getRunMigrationNames =
      fmap migrationName <$>
      (unsafePQ (define createMigrations
      & pqThen (runQuery selectMigrations)) >>= getRows)

    displayListOfNames :: [Text] -> IO ()
    displayListOfNames [] = Text.putStrLn "  None"
    displayListOfNames xs =
      let singleName n = Text.putStrLn $ "  - " <> n
      in traverse_ singleName xs

    displayUnrunned :: [Text] -> IO ()
    displayUnrunned unrunned =
      Text.putStrLn "Migrations left to run:"
      >> displayListOfNames unrunned

    displayRunned :: [Text] -> IO ()
    displayRunned runned =
      Text.putStrLn "Migrations already run:"
      >> displayListOfNames runned

data MigrateIsoCommand
  = MigrateIsoStatus
  | MigrateIsoUp
  | MigrateIsoDown deriving (GHC.Generic, Show)

{- | `mainMigrateIso` creates a simple executable
from a connection string and a `Path` of `Migration` `Iso`s. -}
mainMigrateIso
  :: Migratory p
  => ByteString
  -- ^ connection string
  -> Path (Migration (IsoQ p)) db0 db1
  -- ^ migrations
  -> IO ()
mainMigrateIso connectTo migrations = do
  command <- readCommandFromArgs
  maybe (pure ()) performCommand command

  where

    performCommand :: MigrateIsoCommand -> IO ()
    performCommand = \case
      MigrateIsoStatus -> withConnection connectTo $
        suppressNotices >> migrateStatus
      MigrateIsoUp -> withConnection connectTo $
        suppressNotices & pqThen (migrateUp migrations) & pqThen migrateStatus
      MigrateIsoDown -> withConnection connectTo $
        suppressNotices & pqThen (migrateDown migrations) & pqThen migrateStatus

    migrateStatus :: PQ schema schema IO ()
    migrateStatus = unsafePQ $ do
      runNames <- getRunMigrationNames
      let names = ctoList name migrations
          unrunNames = names \\ runNames
      liftIO $ displayRunned runNames >> displayUnrunned unrunNames

    suppressNotices :: PQ schema schema IO ()
    suppressNotices = manipulate_ $
      UnsafeManipulation "SET client_min_messages TO WARNING;"

    readCommandFromArgs :: IO (Maybe MigrateIsoCommand)
    readCommandFromArgs = getArgs >>= \case
      ["migrate"] -> pure . Just $ MigrateIsoUp
      ["rollback"] -> pure . Just $ MigrateIsoDown
      ["status"] -> pure . Just $ MigrateIsoStatus
      args -> displayUsage args >> pure Nothing

    displayUsage :: [String] -> IO ()
    displayUsage args = do
      putStrLn $ "Invalid command: \"" <> unwords args <> "\". Use:"
      putStrLn "migrate    to run all available migrations"
      putStrLn "rollback   to rollback all available migrations"
      putStrLn "status     to display migrations run and migrations left to run"

    getRunMigrationNames :: (MonadIO m) => PQ db0 db0 m [Text]
    getRunMigrationNames =
      fmap migrationName <$>
        (unsafePQ (define createMigrations
        & pqThen (runQuery selectMigrations)) >>= getRows)

    displayListOfNames :: [Text] -> IO ()
    displayListOfNames [] = Text.putStrLn "  None"
    displayListOfNames xs =
      let singleName n = Text.putStrLn $ "  - " <> n
      in traverse_ singleName xs

    displayUnrunned :: [Text] -> IO ()
    displayUnrunned unrunned =
      Text.putStrLn "Migrations left to run:"
      >> displayListOfNames unrunned

    displayRunned :: [Text] -> IO ()
    displayRunned runned =
      Text.putStrLn "Migrations already run:"
      >> displayListOfNames runned
