{-# language DataKinds #-}
module Indentation where

import Control.Lens.Setter ((.~))
import Control.Lens.Plated (transform)
import GHC.Natural (Natural)

import Language.Python.Internal.Optics
import Language.Python.Internal.Syntax

indentSpaces :: Natural -> Statement '[] a -> Statement '[] a
indentSpaces n = transform (_Indents .~ replicate (fromIntegral n) Space)

indentTabs :: Statement '[] a -> Statement '[] a
indentTabs = transform (_Indents .~ [Tab])
