{-# LANGUAGE DeriveAnyClass, LambdaCase, TupleSections #-}

module Data.Graph.AdjList
  ( AdjList (..)
  , Edge (..)
  , Tag
  , Vertex (..)
  , VertexType (..)
  , graphToAdjList
  , adjListToGraph
  , tagGraph
  , isCoherent
  ) where

import Prologue

import           Algebra.Graph.AdjacencyMap (adjacencyMap)
import           Algebra.Graph.Class (ToGraph (..), edges, vertices)
import           Control.Monad.Effect
import           Control.Monad.Effect.Fresh
import           Data.Aeson
import           Data.Coerce
import           Data.HashMap.Strict ((!))
import qualified Data.HashMap.Strict as HashMap
import           Data.HashSet (HashSet)
import qualified Data.HashSet as HashSet
import           Data.Map (Map)
import qualified Data.Map as Map
import           Data.Set (Set)
import qualified Data.Set as Set
import qualified Data.Vector as Vec
import           Data.Word
import           GHC.Exts (fromList)
import qualified Proto3.Suite as PB

import           Data.Graph
import qualified Data.Graph.Vertex as V

-- | Sum type corresponding to a protobuf enum for vertex types.
data VertexType
  = PACKAGE
  | MODULE
  | VARIABLE
    deriving (Eq, Ord, Show, Enum, Bounded, Generic, ToJSON, FromJSON, PB.Named, PB.Finite, PB.MessageField)

-- | Defaults to 'PACKAGE'.
instance PB.HasDefault VertexType where def = PACKAGE

-- | Piggybacks on top of the 'Enumerated' instance, as the generated code would.
-- This instance will get easier when we have DerivingVia, or a Generic instance
-- that hooks into Enumerated.
instance PB.Primitive VertexType where
  primType _ = PB.primType (Proxy @(PB.Enumerated VertexType))
  encodePrimitive f = PB.encodePrimitive f . PB.Enumerated . Right
  decodePrimitive   = PB.decodePrimitive >>= \case
    (PB.Enumerated (Right r)) -> pure r
    other                     -> Prelude.fail ("VertexType decodeMessageField: unexpected value" <> show other)

-- | A tag used on each vertext of a 'Graph' to convert to an 'AdjList'.
type Tag = Word64

-- | A protobuf-compatible vertex type, with a unique 'Tag' identifier.
data Vertex = Vertex
  { vertexType     :: VertexType
  , vertexContents :: Text
  , vertexTag      :: Tag
  } deriving (Eq, Ord, Show, Generic, PB.Message, PB.Named)

-- | A protobuf-compatible edge type. Only tag information is carried;
-- consumers are expected to look up nodes in the vertex list when necessary.
data Edge = Edge { edgeFrom :: !Tag, edgeTo :: !Tag }
  deriving (Eq, Ord, Show, Generic, Hashable, PB.Named, PB.Message)

-- | An adjacency list-representation of a graph. You generally build these by calling
-- 'graphToAdjList' on an algebraic 'Graph'. This representation is less efficient and
-- fluent than an ordinary 'Graph', but is more amenable to serialization.
data AdjList = AdjList
  { graphVertices :: PB.NestedVec Vertex
  , graphEdges    :: PB.NestedVec Edge
  } deriving (Eq, Ord, Show, Generic, PB.Named, PB.Message)

-- | Convert an algebraic graph to an adjacency list.
graphToAdjList :: Graph V.Vertex -> AdjList
graphToAdjList = taggedGraphToAdjList . tagGraph

-- * Internal interface stuff

-- Using a PBGraph as the accumulator for the fold would incur
-- significant overhead associated with Vector concatenation.
-- We use this and then pay the O(v + e) to-Vector cost once.
data Acc = Acc ![Vertex] !(HashSet Edge)

-- Convert a graph with tagged members to a protobuf-compatible adjacency list.
-- The Tag is necessary to build a canonical adjacency list.
-- Since import graphs can be very large, this is written with speed in mind, in
-- that we convert the graph to algebraic-graphs's 'AdjacencyMap' and then fold
-- to build a 'Graph', avoiding inefficient vector concatenation.
-- Time complexity, given V vertices and E edges, is at least O(2V + 2E + (V * E * log E)),
-- plus whatever overhead converting the graph to 'AdjacencyMap' may entail.
taggedGraphToAdjList :: Graph (V.Vertex, Tag) -> AdjList
taggedGraphToAdjList = accumToAdj . munge . adjacencyMap . toGraph . simplify
  where munge :: Map (V.Vertex, Tag) (Set (V.Vertex, Tag)) -> Acc
        munge = Map.foldlWithKey go (Acc [] mempty)

        go :: Acc -> (V.Vertex, Tag) -> Set (V.Vertex, Tag) -> Acc
        go (Acc vs es) (v, from) edges = Acc (vertexToPB v from : vs) (Set.foldr' add es edges)
          where add (_, to) = HashSet.insert (Edge from to)

        accumToAdj :: Acc -> AdjList
        accumToAdj (Acc vs es) = AdjList (fromList vs) (fromList (toList es))

        vertexToPB :: V.Vertex -> Tag -> Vertex
        vertexToPB s = Vertex t (V.vertexName s) where
          t = case s of
            V.Package{}  -> PACKAGE
            V.Module{}   -> MODULE
            V.Variable{} -> VARIABLE

-- Annotate all vertices of a 'Graph' with a 'Tag', starting from 0.
tagGraph :: Graph vertex -> Graph (vertex, Tag)
tagGraph = run . runFresh 1 . go where
  go :: Graph vertex -> Eff '[Fresh] (Graph (vertex, Tag))
  go = traverse (\v -> (v, ) . fromIntegral <$> fresh)

-- | This is the reverse of 'graphToAdjList'. Don't use this outside of a testing context.
-- N.B. @adjListToGraph . graphToAdjList@ is 'id', but @graphToAdjList . adjListToGraph@ is not.
adjListToGraph :: AdjList -> Graph V.Vertex
adjListToGraph (AdjList vs es) = simplify built
  where built = allEdges <> vertices unreferencedVertices

        allEdges :: Graph V.Vertex
        allEdges = fmap fst (edges (foldr addEdge [] es))
        addEdge (Edge f t) xs = ((adjMap ! f, f), (adjMap ! t, t)) : xs
        adjMap = foldMap (\v -> HashMap.singleton (vertexTag v) (pbToVertex v)) vs

        unreferencedVertices :: [V.Vertex]
        unreferencedVertices = pbToVertex <$> toList (Vec.filter isUnreferenced (coerce vs))

        isUnreferenced :: Vertex -> Bool
        isUnreferenced v = not (vertexTag v `HashSet.member` edgedTags)

        edgedTags :: HashSet Tag
        edgedTags = HashSet.fromList $ concatMap unEdge es where unEdge (Edge f t) = [f, t]

        pbToVertex :: Vertex -> V.Vertex
        pbToVertex (Vertex t c _) = case t of
          MODULE   -> V.Module c
          PACKAGE  -> V.Package c
          VARIABLE -> V.Variable c


-- | For debugging: returns True if all edges reference a valid vertex tag.
isCoherent :: AdjList -> Bool
isCoherent (AdjList vs es) = all edgeValid es where
  edgeValid (Edge a b) = HashSet.member a allTags && HashSet.member b allTags
  allTags = HashSet.fromList (toList (vertexTag <$> vs))
