{-# LANGUAGE CPP #-}
{-# LANGUAGE TemplateHaskell #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE TupleSections #-}
-- |
-- Module: Database.PostgreSQL.Typed.Models
-- Copyright: 2016 Dylan Simon
-- 
-- Automatically create data models based on tables.

module Database.PostgreSQL.Typed.Models
  ( dataPGTable
  ) where

import qualified Data.ByteString.Lazy as BSL
import qualified Language.Haskell.TH as TH

import           Database.PostgreSQL.Typed.Types
import           Database.PostgreSQL.Typed.Dynamic
import           Database.PostgreSQL.Typed.Protocol
import           Database.PostgreSQL.Typed.TypeCache
import           Database.PostgreSQL.Typed.TH

-- |Create a new data type corresponding to the given PostgreSQL table.
-- For example, if you have @CREATE TABLE foo (abc integer NOT NULL, def text);@, then
-- @dataPGTable \"Foo\" \"foo\" (\"foo_\"++)@ will be equivalent to:
-- 
-- > data Foo = Foo{ foo_abc :: PGVal "integer", foo_def :: Maybe (PGVal "text") }
-- > instance PGType "foo" where PGVal "foo" = Foo
-- > instance PGParameter "foo" Foo where ...
-- > instance PGColumn "foo" Foo where ...
-- > instance PGColumn "foo" (Maybe Foo) where ... -- to handle NULL in not null columns
-- > instance PGRep Foo where PGRepType = "foo"
-- > instance PGRecordType "foo"
-- > uncurryFoo :: (PGVal "integer", Maybe (PGVal "text")) -> Foo
--
-- (Note that @PGVal "integer" = Int32@ and @PGVal "text" = Text@ by default.)
-- This provides instances for marshalling the corresponding composite/record types, e.g., using @SELECT foo.*::foo FROM foo@.
-- If you want any derived instances, you'll need to create them yourself using StandaloneDeriving.
--
-- Requires language extensions: TemplateHaskell, FlexibleInstances, MultiParamTypeClasses, DataKinds, TypeFamilies, PatternGuards
dataPGTable :: String -- ^ Haskell type and constructor to create 
  -> String -- ^ PostgreSQL table/relation name
  -> (String -> String) -- ^ How to generate field names from column names, e.g. @("table_" ++)@
  -> TH.DecsQ
dataPGTable typs pgtab colf = do
  (pgid, cold) <- TH.runIO $ withTPGTypeConnection $ \tpg -> do
    cl <- mapM (\[to, cn, ct, cnn] -> do
      let n = pgDecodeRep cn
          o = pgDecodeRep ct
      t <- maybe (fail $ "dataPGTable " ++ typs ++ " = " ++ pgtab ++ ": column '" ++ n ++ "' has unknown type " ++ show o) return
        =<< lookupPGType tpg o
      return (pgDecodeRep to, (n, TH.LitT (TH.StrTyLit t), pgDecodeRep cnn)))
      . snd =<< pgSimpleQuery (pgConnection tpg) (BSL.fromChunks
        [ "SELECT reltype, attname, atttypid, attnotnull"
        ,  " FROM pg_catalog.pg_attribute"
        ,  " JOIN pg_catalog.pg_class ON attrelid = pg_class.oid"
        , " WHERE attrelid = ", pgLiteralRep pgtab, "::regclass"
        ,   " AND attnum > 0 AND NOT attisdropped"
        , " ORDER BY attnum"
        ])
    case cl of
      [] -> fail $ "dataPGTable " ++ typs ++ " = " ++ pgtab ++ ": no columns found"
      (to, _):_ -> do
        tt <- maybe (fail $ "dataPGTable " ++ typs ++ " = " ++ pgtab ++ ": table type not found (you may need to use reloadTPGTypes or adjust search_path)") return
          =<< lookupPGType tpg to
        return (tt, map snd cl)
  cols <- mapM (\(n, t, nn) -> do
      v <- TH.newName n
      return (v, t, not nn))
    cold
  let typl = TH.LitT (TH.StrTyLit pgid)
      encfun f = TH.FunD f [TH.Clause [TH.WildP, TH.ConP typn (map (\(v, _, _) -> TH.VarP v) cols)]
        (TH.NormalB $ pgcall f rect `TH.AppE`
          (TH.ConE 'PGRecord `TH.AppE` TH.ListE (map (colenc f) cols)))
        [] ]
  dv <- TH.newName "x"
  tv <- TH.newName "t"
  ev <- TH.newName "e"
  return
    [ TH.DataD
      []
      typn
      []
#if MIN_VERSION_template_haskell(2,11,0)
      Nothing
#endif
      [ TH.RecC typn $ map (\(n, t, nn) ->
        ( TH.mkName (colf n)
#if MIN_VERSION_template_haskell(2,11,0)
        , TH.Bang TH.NoSourceUnpackedness TH.NoSourceStrictness
#else
        , TH.NotStrict
#endif
        , (if nn then id else (TH.ConT ''Maybe `TH.AppT`))
          (TH.ConT ''PGVal `TH.AppT` t)))
        cold
      ]
      []
    , instanceD [] (TH.ConT ''PGType `TH.AppT` typl)
      [ TH.TySynInstD ''PGVal $ TH.TySynEqn [typl] typt
      ]
    , instanceD [] (TH.ConT ''PGParameter `TH.AppT` typl `TH.AppT` typt)
      [ encfun 'pgEncode
      , encfun 'pgLiteral
      ]
    , instanceD [] (TH.ConT ''PGColumn `TH.AppT` typl `TH.AppT` typt)
      [ TH.FunD 'pgDecode [TH.Clause [TH.WildP, TH.VarP dv]
        (TH.GuardedB
          [ (TH.PatG [TH.BindS
              (TH.ConP 'PGRecord [TH.ListP $ map colpat cols])
              (pgcall 'pgDecode rect `TH.AppE` TH.VarE dv)]
            , foldl (\f -> TH.AppE f . coldec) (TH.ConE typn) cols)
          , (TH.NormalG (TH.ConE 'True)
            , TH.VarE 'error `TH.AppE` TH.LitE (TH.StringL $ "pgDecode " ++ typs ++ ": NULL in not null record column"))
          ])
        [] ]
      ]
#if MIN_VERSION_template_haskell(2,11,0)
    , TH.InstanceD (Just TH.Overlapping) [] (TH.ConT ''PGColumn `TH.AppT` typl `TH.AppT` (TH.ConT ''Maybe `TH.AppT` typt))
      [ TH.FunD 'pgDecode [TH.Clause [TH.WildP, TH.VarP dv]
        (TH.GuardedB
          [ (TH.PatG [TH.BindS
              (TH.ConP 'PGRecord [TH.ListP $ map colpat cols])
              (pgcall 'pgDecode rect `TH.AppE` TH.VarE dv)]
            , TH.ConE 'Just `TH.AppE` foldl (\f -> TH.AppE f . coldec) (TH.ConE typn) cols)
          , (TH.NormalG (TH.ConE 'True)
            , TH.ConE 'Nothing)
          ])
        [] ]
#endif
      , TH.FunD 'pgDecodeValue 
        [ TH.Clause [TH.WildP, TH.WildP, TH.ConP 'PGNullValue []]
          (TH.NormalB $ TH.ConE 'Nothing)
          []
        , TH.Clause [TH.WildP, TH.VarP tv, TH.ConP 'PGTextValue [TH.VarP dv]]
          (TH.NormalB $ TH.VarE 'pgDecode `TH.AppE` TH.VarE tv `TH.AppE` TH.VarE dv)
          []
        , TH.Clause [TH.VarP ev, TH.VarP tv, TH.ConP 'PGBinaryValue [TH.VarP dv]]
          (TH.NormalB $ TH.VarE 'pgDecodeBinary `TH.AppE` TH.VarE ev `TH.AppE` TH.VarE tv `TH.AppE` TH.VarE dv)
          []
        ]
      ]
    , instanceD [] (TH.ConT ''PGRep `TH.AppT` typt)
      [ TH.TySynInstD ''PGRepType $ TH.TySynEqn [typt] typl
      ]
    , instanceD [] (TH.ConT ''PGRecordType `TH.AppT` typl) []
    , TH.SigD (TH.mkName ("uncurry" ++ typs)) $ TH.ArrowT `TH.AppT`
      foldl (\f (_, t, n) -> f `TH.AppT`
          (if n then (TH.ConT ''Maybe `TH.AppT`) else id)
          (TH.ConT ''PGVal `TH.AppT` t))
        (TH.ConT (TH.tupleTypeName (length cols)))
        cols `TH.AppT` typt
    , TH.FunD (TH.mkName ("uncurry" ++ typs))
      [ TH.Clause [TH.ConP (TH.tupleDataName (length cols)) (map (\(v, _, _) -> TH.VarP v) cols)]
        (TH.NormalB $ foldl (\f (v, _, _) -> f `TH.AppE` TH.VarE v) (TH.ConE typn) cols)
        []
      ]
    ]
  where
  typn = TH.mkName typs
  typt = TH.ConT typn
  instanceD = TH.InstanceD
#if MIN_VERSION_template_haskell(2,11,0)
      Nothing
#endif
  pgcall f t = TH.VarE f `TH.AppE`
    (TH.ConE 'PGTypeProxy `TH.SigE`
      (TH.ConT ''PGTypeID `TH.AppT` t))
  colenc f (v, t, False) = TH.ConE 'Just `TH.AppE` (pgcall f t `TH.AppE` TH.VarE v)
  colenc f (v, t, True) = TH.VarE 'fmap `TH.AppE` pgcall f t `TH.AppE` TH.VarE v
  colpat (v, _, False) = TH.ConP 'Just [TH.VarP v]
  colpat (v, _, True) = TH.VarP v
  coldec (v, t, False) = pgcall 'pgDecode t `TH.AppE` TH.VarE v
  coldec (v, t, True) = TH.VarE 'fmap `TH.AppE` pgcall 'pgDecode t `TH.AppE` TH.VarE v
  rect = TH.LitT $ TH.StrTyLit "record"
