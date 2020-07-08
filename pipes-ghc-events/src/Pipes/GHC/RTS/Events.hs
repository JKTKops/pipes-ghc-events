module Pipes.GHC.RTS.Events
  ( decodeEventLog
  , decodeHeader
  , decodeEvents
  ) where

import Data.ByteString (ByteString)
import Pipes (Pipe)
import Pipes (Producer)
import GHC.RTS.Events (Event)

import Control.Monad.Trans.State.Strict (runStateT)
import Pipes ((>->))

import qualified Control.Monad.Trans.Class as Trans
import qualified GHC.RTS.Events as GHC
import qualified GHC.RTS.Events.Incremental as GHC
import qualified Pipes as Pipes
import qualified Pipes.Parse as Pipes

decodeHeader
  :: Monad m
  => Producer ByteString m x
  -> m (GHC.Header, Producer ByteString m x)
decodeHeader = runStateT (go GHC.decodeHeader)
  where
    go = \case
      GHC.Produce header decoder' ->
        case decoder' of
          GHC.Done leftover ->
            do
              Pipes.unDraw leftover
              return header
          _ -> error "decodeHeader: Unexpected decoder"
      GHC.Consume continue ->
        Pipes.draw >>= \case
          Nothing -> error "decodeHeader: Unexpected end of input"
          Just bytes -> go (continue bytes)
      GHC.Done _ -> error "decodeHeader: Unexpected termination"
      GHC.Error _ err -> error ("decodeHeader: " ++ err)

decodeEvents :: forall m r. Monad m => GHC.Header -> Pipe ByteString Event m r
decodeEvents header = begin []
  where
    begin = go (GHC.decodeEvents header)

    go :: GHC.Decoder Event -> [ByteString] -> Pipe ByteString Event m r
    go decoder leftovers =
      case decoder of
        GHC.Produce event decoder' ->
          do
            Pipes.yield event
            go decoder' leftovers
        GHC.Consume continue ->
          case leftovers of
            bytes : bytess -> go (continue bytes) bytess
            [] ->
              do
                bytes <- Pipes.await
                go (continue bytes) []
        GHC.Done leftover -> begin (leftover : leftovers)
        GHC.Error _ err -> error ("decodeEvents: " ++ err)

decodeEventLog
  :: Monad m
  => Producer ByteString m x
  -> Producer Event m x
decodeEventLog producer =
  do
    (header, producer') <- Trans.lift $ decodeHeader producer
    producer' >-> decodeEvents header
