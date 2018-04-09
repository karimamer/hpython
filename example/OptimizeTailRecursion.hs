{-# language OverloadedLists, OverloadedStrings #-}
{-# language DataKinds #-}
module OptimizeTailRecursion where

import Control.Lens.Cons (_last, _init)
import Control.Lens.Fold ((^..), (^?), (^?!), allOf, anyOf, folded, foldrOf, toListOf)
import Control.Lens.Getter ((^.))
import Control.Lens.Plated (cosmos, transform, transformOn)
import Control.Lens.Prism (_Just)
import Control.Lens.Setter ((%~))
import Control.Lens.Tuple (_1, _2, _3, _4)
import Data.Foldable (toList)
import qualified Data.List.NonEmpty as NonEmpty
import Data.Semigroup ((<>))

import Language.Python.Internal.Optics
import Language.Python.Internal.Syntax
import Language.Python.Syntax

optimizeTailRecursion :: Statement '[] () -> Maybe (Statement '[] ())
optimizeTailRecursion st = do
  (_, _, name, _, params, _, _, _, body) <- st ^? _Fundef
  bodyLast <- toListOf (unvalidated._Statements) body ^? _last

  let
    params' = toList params
    paramNames = (_identValue . _paramName) <$> params'

  if not $ hasTC (name ^. identValue) bodyLast
    then Nothing
    else
      Just .
      def_ name params' . NonEmpty.fromList $
        zipWith (\a b -> var_ (a <> "__tr") .= var_ b) paramNames paramNames <>
        [ "__res__tr" .= none_
        , while_ true_ . NonEmpty.fromList .
          transformOn (traverse._Exprs) (renameIn paramNames "__tr") $
            (toListOf (unvalidated._Statements) body ^?! _init) <>
            looped (name ^. identValue) paramNames bodyLast
        , return_ "__res__tr"
        ]

  where
    isTailCall :: String -> Expr '[] () -> Bool
    isTailCall name e
      | anyOf (cosmos._Call._2._Ident._2.identValue) (== name) e
      = (e ^? _Call._2._Ident._2.identValue) == Just name
      | otherwise = False

    hasTC :: String -> Statement '[] () -> Bool
    hasTC name st =
      case st of
        CompoundStatement (If _ _ e _ _ _ sts sts') ->
          allOf _last (hasTC name) (sts ^.. _Statements) ||
          allOf _last (hasTC name) (sts' ^.. _Just._4._Statements)
        SmallStatements s ss _ _ ->
          case last (s : fmap (^. _3) ss) of
            Return _ _ e -> isTailCall name e
            Expr _ e -> isTailCall name e
            _ -> False
        _ -> False

    renameIn :: [String] -> String -> Expr '[] () -> Expr '[] ()
    renameIn params suffix =
      transform
        (_Ident._2.identValue %~ (\a -> if a `elem` params then a <> suffix else a))

    looped :: String -> [String] -> Statement '[] () -> [Statement '[] ()]
    looped name params st =
      case st of
        CompoundStatement c ->
          case c of
            If _ _ e _ _ _ sts sts'
              | hasTC name st ->
                  case sts' of
                    Nothing ->
                      [ if_ e
                          (NonEmpty.fromList $
                          (toListOf _Statements sts ^?! _init) <>
                          looped name params (toListOf _Statements sts ^?! _last))
                      ]
                    Just (_, _, _, sts'') ->
                      [ ifElse_ e
                          (NonEmpty.fromList $
                          (toListOf _Statements sts ^?! _init) <>
                          looped name params (toListOf _Statements sts ^?! _last))
                          (NonEmpty.fromList $
                          (toListOf _Statements sts'' ^?! _init) <>
                          looped name params (toListOf _Statements sts'' ^?! _last))
                      ]
            _ -> [st]
        SmallStatements s ss sc nl ->
          let
            initExps = foldr (\_ _ -> init ss) [] ss
            lastExp =
              foldrOf (folded._3) (\_ _ -> last ss ^. _3) s ss
            newSts =
              case initExps of
                [] -> []
                (_, _, a) : rest ->
                  let
                    lss = last ss
                  in
                    [SmallStatements a rest (Just (lss ^. _1, lss ^. _2)) nl]
          in
            case lastExp of
              Return _ _ e ->
                case e ^? _Call of
                  Just (_, f, _, args)
                    | Just name' <- f ^? _Ident._2.identValue
                    , name' == name ->
                        newSts <>
                        fmap (\a -> var_ (a <> "__tr__old") .= (var_ $ a <> "__tr")) params <>
                        zipWith
                          (\a b -> var_ (a <> "__tr") .= b)
                          params
                          (transformOn traverse (renameIn params "__tr__old") $ args ^.. folded.argExpr)
                  _ -> newSts <> [ "__res__tr" .= e, break_ ]
              Expr _ e
                | isTailCall name e -> newSts <> [pass_]
              _ -> [st]
