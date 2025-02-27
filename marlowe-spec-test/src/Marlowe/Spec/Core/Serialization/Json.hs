{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TypeApplications #-}
{-# LANGUAGE BlockArguments #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}

module Marlowe.Spec.Core.Serialization.Json where

import Control.Applicative ((<|>))
import Data.Aeson.Types (Result(..), ToJSON(..), FromJSON(..))
import Data.Aeson (object, (.=), (.:), withObject)
import qualified Data.Aeson.Types as JSON
import Data.Text as T
import Data.Proxy (Proxy(..))
import MarloweCoreJson
import GHC.Stack (HasCallStack)
import Test.Tasty (TestTree, testGroup)
import Marlowe.Spec.Interpret (Response (..), InterpretJsonRequest, Request (..), testResponse)
import Marlowe.Spec.TypeId (TypeId(..), HasTypeId (..))
import Test.Tasty.HUnit (Assertion, assertBool, testCase, (@=?))
import qualified SemanticsTypes as C
import Marlowe.Spec.Core.Arbitrary (genToken, genParty, genPayee, genChoiceId, genBound, genValue, genObservation, genAction, genContract, genInput, genTransaction, genPayment, genState, genTransactionWarning, genIntervalError, genTransactionError, genTransactionOutput)
import Control.Monad.IO.Class (MonadIO)
import Marlowe.Spec.Reproducible (generate, generateT, reproducibleProperty, assertResponse)
import QuickCheck.GenT (MonadGen (resize))
import Test.QuickCheck.Monadic (run, PropertyM)

data SerializationResponse transport
  = SerializationSuccess transport
  | UnknownType TypeId
  | SerializationError String
  deriving (Eq)

instance ToJSON (SerializationResponse JSON.Value) where
  toJSON (SerializationSuccess result) = object
    [ "serialization-success" .= result
    ]
  toJSON (UnknownType t) = object
    [ "unknown-type" .= toJSON t
    ]
  toJSON (SerializationError err) = object
    [ "serialization-error" .= JSON.String (T.pack err)
    ]

instance FromJSON (SerializationResponse JSON.Value) where
  parseJSON = withObject "SerializationResponse" $
      \v -> asSuccess v <|> asUnknownType v <|> asError v
    where
    asSuccess v = SerializationSuccess <$> v .: "serialization-success"
    asUnknownType v = UnknownType <$> v .: "unknown-type"
    asError v = SerializationError <$> v .: "serialization-error"

tests :: InterpretJsonRequest -> TestTree
tests i = testGroup "Json Serialization"
  [ exampleTest i
  , arbitraryTests i
  ]

exampleTest :: InterpretJsonRequest -> TestTree
exampleTest i = testGroup "Examples"
  [ testCase "Bound example" $ unitRoundtripTest i exampleBound
  , valueExamples i
  , observationTests i
  , invalidType i
  ]

arbitraryTests :: InterpretJsonRequest -> TestTree
arbitraryTests i = testGroup "Arbitrary"
  [ arbitraryTokenTest i
  , arbitraryPartyTest i
  , arbitraryPayeeTest i
  , arbitraryChoiceIdTest i
  , arbitraryBoundTest i
  , arbitraryValueTest i
  , arbitraryObservationTest i
  , arbitraryActionTest i
  , arbitraryContractTest i
  , arbitraryInputTest i
  , arbitraryTransactionTest i
  , arbitraryPaymentTest i
  , arbitraryStateTest i
  , arbitraryTransactionWarningTest i
  , arbitraryIntervalErrorTest i
  , arbitraryTransactionErrorTest i
  , arbitraryTransactionOutputTest i
  ]

valueExamples :: InterpretJsonRequest -> TestTree
valueExamples i = testGroup "Value examples"
  [ testCase "Constant" $ unitRoundtripTest i constantExample
  , testCase "Interval start" $ unitRoundtripTest i intervalStartExample
  , testCase "Interval end" $ unitRoundtripTest i intervalEndExample
  , testCase "Add" $ unitRoundtripTest i addExample
  , testCase "Sub" $ unitRoundtripTest i subExample
  , testCase "Mul" $ unitRoundtripTest i mulExample
  , testCase "Div" $ unitRoundtripTest i divExample
  , testCase "Negate" $ unitRoundtripTest i negateExample
  , testCase "Use" $ unitRoundtripTest i useValueExample
  , testCase "Cond" $ unitRoundtripTest i condExample
  , testResponse i "Invalid value"
    (TestRoundtripSerialization
      (TypeId "Core.Value" (Proxy @C.Value))
      (JSON.String "invalid value")
    )
    assertSerializationError
  ]

observationTests :: InterpretJsonRequest -> TestTree
observationTests i = testGroup "Observation examples"
  [ testCase "True" $ unitRoundtripTest i trueExample
  , testCase "False" $ unitRoundtripTest i falseExample
  , testCase "And" $ unitRoundtripTest i andExample
  , testCase "Or" $ unitRoundtripTest i orExample
  , testCase "Not" $ unitRoundtripTest i notExample
  , testCase "Value GE" $ unitRoundtripTest i valueGEExample
  , testCase "Value GT" $ unitRoundtripTest i valueGTExample
  , testCase "Value LT" $ unitRoundtripTest i valueLTExample
  , testCase "Value LE" $ unitRoundtripTest i valueLEExample
  , testCase "Value EQ" $ unitRoundtripTest i valueEQExample
  , testResponse i "Invalid observation"
    (TestRoundtripSerialization (TypeId "Core.Observation" (Proxy :: Proxy C.Observation)) (JSON.String "invalid"))
    assertSerializationError

  ]

invalidType :: InterpretJsonRequest -> TestTree
invalidType i = testResponse i "Invalid type"
    (TestRoundtripSerialization (TypeId "InvalidType" (Proxy :: Proxy ())) (JSON.String "invalid"))
    assertUnknownType

unitRoundtripTest :: (HasTypeId a, ToJSON a) => InterpretJsonRequest -> a -> Assertion
unitRoundtripTest interpret a = do
  res <- interpret serializationRequest
  successResponse @=? res
  where
  serializationRequest = TestRoundtripSerialization (getTypeId a) $ toJSON a
  successResponse = RequestResponse $ toJSON $ SerializationSuccess $ toJSON a

propertyRoundtripTest :: (HasTypeId a, ToJSON a, MonadIO m) => InterpretJsonRequest -> a -> PropertyM m ()
propertyRoundtripTest interpret a = do
  assertResponse interpret serializationRequest successResponse
  where
  serializationRequest = TestRoundtripSerialization (getTypeId a) $ toJSON a
  successResponse = RequestResponse $ toJSON $ SerializationSuccess $ toJSON a

assertSerializationError :: HasCallStack => Response JSON.Value -> Assertion
assertSerializationError = assertBool "The serialization response should be SerializationError" . isSerializationError

isSerializationError :: Response JSON.Value -> Bool
isSerializationError (RequestResponse res) = case JSON.fromJSON res :: Result (SerializationResponse JSON.Value) of
  (Success (SerializationError _)) -> True
  _ -> False
isSerializationError _ = False

assertUnknownType :: HasCallStack => Response JSON.Value -> Assertion
assertUnknownType = assertBool "The serialization response should be UnknownType" . isUnknownType

isUnknownType :: Response JSON.Value -> Bool
isUnknownType (RequestResponse res) = case JSON.fromJSON res :: Result (SerializationResponse JSON.Value) of
  (Success (UnknownType _)) -> True
  _ -> False
isUnknownType _ = False

arbitraryTokenTest :: InterpretJsonRequest -> TestTree
arbitraryTokenTest i = reproducibleProperty "Token" do
  -- Any token that is randomly generated by the interpreter should also pass the roundtrip test
  token <- run $ generateT $ genToken i
  propertyRoundtripTest i token

arbitraryPartyTest :: InterpretJsonRequest -> TestTree
arbitraryPartyTest i = reproducibleProperty "Party" do
  -- Any party that is randomly generated by the interpreter should also pass the roundtrip test
  party <- run $ generateT $ genParty i
  propertyRoundtripTest i party

arbitraryPayeeTest :: InterpretJsonRequest -> TestTree
arbitraryPayeeTest i = reproducibleProperty "Payee" do
  payee <- run $ generateT $ genPayee i
  propertyRoundtripTest i payee

arbitraryChoiceIdTest :: InterpretJsonRequest -> TestTree
arbitraryChoiceIdTest i = reproducibleProperty "ChoiceId" do
  choiceId <- run $ generateT $ genChoiceId i
  propertyRoundtripTest i choiceId

arbitraryBoundTest :: InterpretJsonRequest -> TestTree
arbitraryBoundTest i = reproducibleProperty "Bound" do
  bound <- run $ generate genBound
  propertyRoundtripTest i bound

arbitraryValueTest :: InterpretJsonRequest -> TestTree
arbitraryValueTest i = reproducibleProperty "Value" do
  value <- run $ generateT $ resize 15 $ genValue i
  propertyRoundtripTest i value

arbitraryObservationTest :: InterpretJsonRequest -> TestTree
arbitraryObservationTest i = reproducibleProperty "Observation" do
  observation <- run $ generateT $ resize 15 $ genObservation i
  propertyRoundtripTest i observation

arbitraryActionTest :: InterpretJsonRequest -> TestTree
arbitraryActionTest i = reproducibleProperty "Action" do
  action <- run $ generateT $ resize 15 $ genAction i
  propertyRoundtripTest i action

arbitraryContractTest :: InterpretJsonRequest -> TestTree
arbitraryContractTest i = reproducibleProperty "Contract" do
  contract <- run $ generateT $ resize 10 $ genContract i
  propertyRoundtripTest i contract

arbitraryInputTest :: InterpretJsonRequest -> TestTree
arbitraryInputTest i = reproducibleProperty "Input" do
  input <- run $ generateT $ genInput i
  propertyRoundtripTest i input

arbitraryTransactionTest :: InterpretJsonRequest -> TestTree
arbitraryTransactionTest i = reproducibleProperty "Transaction" do
  tx <- run $ generateT $ genTransaction i
  propertyRoundtripTest i tx

arbitraryPaymentTest :: InterpretJsonRequest -> TestTree
arbitraryPaymentTest i = reproducibleProperty "Payment" do
    payment <- run $ generateT $ genPayment i
    propertyRoundtripTest i payment

arbitraryStateTest :: InterpretJsonRequest -> TestTree
arbitraryStateTest i = reproducibleProperty "State" do
  state <- run $ generateT $ genState i
  propertyRoundtripTest i state

arbitraryTransactionWarningTest :: InterpretJsonRequest -> TestTree
arbitraryTransactionWarningTest i = reproducibleProperty "TransactionWarning" do
  warning <- run $ generateT $ genTransactionWarning i
  propertyRoundtripTest i warning

arbitraryIntervalErrorTest :: InterpretJsonRequest -> TestTree
arbitraryIntervalErrorTest i = reproducibleProperty "IntervalError" do
  warning <- run $ generate $ genIntervalError
  propertyRoundtripTest i warning

arbitraryTransactionErrorTest :: InterpretJsonRequest -> TestTree
arbitraryTransactionErrorTest i = reproducibleProperty "TransactionError" do
  txError <- run $ generate $ genTransactionError
  propertyRoundtripTest i txError

arbitraryTransactionOutputTest :: InterpretJsonRequest -> TestTree
arbitraryTransactionOutputTest i = reproducibleProperty "TransactionOutput" do
  out <- run $ generateT $ genTransactionOutput i
  propertyRoundtripTest i out

