module IHP.DataSync.RowLevelSecurity
( withRLS
, ensureRLSEnabled
, hasRLSEnabled
, TableWithRLS (tableName)
, makeCachedEnsureRLSEnabled
)
where

import IHP.ControllerPrelude
import qualified Database.PostgreSQL.Simple as PG
import qualified Database.PostgreSQL.Simple.ToField as PG
import qualified Database.PostgreSQL.Simple.Types as PG
import qualified IHP.DataSync.Role as Role

import Network.HTTP.Types (status400)

import Data.Set (Set)
import qualified Data.Set as Set

withRLS :: forall userId result.
    ( PG.ToField userId
    , userId ~ Id CurrentUserRecord
    , Show (PrimaryKey (GetTableName CurrentUserRecord))
    , HasNewSessionUrl CurrentUserRecord
    , Typeable CurrentUserRecord
    , ?context :: ControllerContext
    , HasField "id" CurrentUserRecord (Id' (GetTableName CurrentUserRecord))
    , ?modelContext :: ModelContext
    ) => ((?modelContext :: ModelContext) => IO result) -> IO result
withRLS callback = withTransaction inner
    where
        -- The inner call is required here as we need to capture the right ?modelContext
        -- from withTransaction, otherwise the wrong database connection is used
        inner :: (?modelContext :: ModelContext) => IO result
        inner = do
            let maybeUserId :: Maybe userId = get #id <$> currentUserOrNothing
            sqlExec "SET LOCAL ROLE ?" [PG.Identifier Role.authenticatedRole]

            -- When the user is not logged in and maybeUserId is Nothing, we cannot
            -- just pass @NULL@ to postgres. The @SET LOCAL@ values can only be strings.
            --
            -- Therefore we map Nothing to an empty string here. The empty string
            -- means "not logged in".
            --
            let encodedUserId = case maybeUserId of
                    Just userId -> PG.toField userId
                    Nothing -> PG.toField ("" :: Text)
            sqlExec "SET LOCAL rls.ihp_user_id = ?" (PG.Only encodedUserId)
            callback

-- | Returns a proof that RLS is enabled for a table
ensureRLSEnabled :: (?modelContext :: ModelContext) => Text -> IO TableWithRLS
ensureRLSEnabled table = do
    rlsEnabled <- hasRLSEnabled table
    unless rlsEnabled (error "Row level security is required for accessing this table")
    pure (TableWithRLS table)

-- | Returns a factory for 'ensureRLSEnabled' that memoizes when a table has RLS enabled.
--
-- When a table doesn't have RLS enabled yet, the result is not memoized.
--
-- __Example:__
--
-- > -- Setup
-- > ensureRLSEnabled <- makeCachedEnsureRLSEnabled
-- >
-- > ensureRLSEnabled "projects" -- Runs a database query to check if row level security is enabled for the projects table
-- >
-- > -- Asuming 'ensureRLSEnabled "projects"' proceeded without errors:
-- >
-- > ensureRLSEnabled "projects" -- Now this will instantly return True and don't fire any SQL queries anymore
--
makeCachedEnsureRLSEnabled :: (?modelContext :: ModelContext) => IO (Text -> IO TableWithRLS)
makeCachedEnsureRLSEnabled = do
    tables <- newIORef Set.empty
    pure \tableName -> do
        rlsEnabled <- Set.member tableName <$> readIORef tables

        if rlsEnabled
            then pure TableWithRLS { tableName }
            else do
                proof <- ensureRLSEnabled tableName
                modifyIORef' tables (Set.insert tableName)
                pure proof

-- | Returns 'True' if row level security has been enabled on a table
--
-- RLS can be enabled with this SQL statement:
--
-- > ALTER TABLE my_table ENABLE ROW LEVEL SECURITY;
--
-- After this 'hasRLSEnabled' will return true:
--
-- >>> hasRLSEnabled "my_table"
-- True
hasRLSEnabled :: (?modelContext :: ModelContext) => Text -> IO Bool
hasRLSEnabled table = sqlQueryScalar "SELECT relrowsecurity FROM pg_class WHERE oid = ?::regclass" [table]

-- | Can be constructed using 'ensureRLSEnabled'
--
-- > tableWithRLS <- ensureRLSEnabled "my_table"
--
-- Useful to carry a proof that the RLS is actually enabled
newtype TableWithRLS = TableWithRLS { tableName :: Text }