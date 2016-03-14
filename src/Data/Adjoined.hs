{-# LANGUAGE GeneralizedNewtypeDeriving #-}
module Data.Adjoined where

import Control.Applicative
import Control.Monad
import Data.Align
import Data.Bifunctor.These
import Data.Coalescent
import Data.Sequence as Seq hiding (null)

-- | A collection of elements which can be adjoined onto other such collections associatively.
newtype Adjoined a = Adjoined { unAdjoined :: Seq a }
  deriving (Eq, Foldable, Functor, Show, Traversable)

-- | Construct an Adjoined from a list.
fromList :: [a] -> Adjoined a
fromList = Adjoined . Seq.fromList

-- | Construct Adjoined by adding an element at the left.
cons :: a -> Adjoined a -> Adjoined a
cons a (Adjoined as) = Adjoined (a <| as)

-- | Destructure a non-empty Adjoined into Just the leftmost element and the rightward remainder of the Adjoined, or Nothing otherwise.
uncons :: Adjoined a -> Maybe (a, Adjoined a)
uncons (Adjoined v) | a :< as <- viewl v = Just (a, Adjoined as)
                    | otherwise = Nothing

-- | Construct Adjoined by adding an element at the right.
snoc :: Adjoined a -> a -> Adjoined a
snoc (Adjoined as) a = Adjoined (as |> a)

-- | Destructure a non-empty Adjoined into Just the rightmost element and the leftward remainder of the Adjoined, or Nothing otherwise.
unsnoc :: Adjoined a -> Maybe (Adjoined a, a)
unsnoc (Adjoined v) | as :> a <- viewr v = Just (Adjoined as, a)
                    | otherwise = Nothing

instance Applicative Adjoined where
  pure = return
  (<*>) = ap

instance Alternative Adjoined where
  empty = Adjoined mempty
  Adjoined a <|> Adjoined b = Adjoined (a >< b)

instance Monad Adjoined where
  return = Adjoined . return
  Adjoined a >>= f = case viewl a of
    EmptyL -> Adjoined Seq.empty
    (a :< as) -> Adjoined $ unAdjoined (f a) >< unAdjoined (Adjoined as >>= f)

instance Coalescent a => Monoid (Adjoined a) where
  mempty = Adjoined mempty
  a `mappend` b | Just (as, a) <- unsnoc a,
                  Just (b, bs) <- uncons b
                = as <|> coalesce a b <|> bs
                | otherwise = Adjoined (unAdjoined a >< unAdjoined b)

instance Align Adjoined where
  nil = Adjoined mempty
  align as bs | Just (as, a) <- unsnoc as,
                Just (bs, b) <- unsnoc bs = align as bs `snoc` These a b
              | null bs = This <$> as
              | null as = That <$> bs
              | otherwise = nil
