{-# LANGUAGE OverloadedLists #-}
{-# LANGUAGE TemplateHaskell #-}
module Language.Marlowe.Analysis.FSSemantics where

import           Data.List       (foldl')
import           Data.Map.Strict (Map)
import qualified Data.Map.Strict as M
import           Data.Ratio (denominator, numerator)
import           Data.Set        (Set)
import qualified Data.Set        as S
import           Data.SBV
import           Data.SBV.Internals (SMTModel(..))
import qualified Data.SBV.Tuple as ST
import qualified Data.SBV.Either as SE
import qualified Data.SBV.Maybe as SM
import qualified Data.SBV.List as SL
import qualified Language.Marlowe.Analysis.IntegerArray as IntegerArray
import           Language.Marlowe.Analysis.IntegerArray (IntegerArray, NIntegerArray)
import Language.Marlowe.Analysis.Numbering (Numbering, emptyNumbering, getNumbering, getLabel, numberOfLabels)
import           Language.Marlowe.Analysis.MkSymb(mkSymbolicDatatype)
import qualified Language.Marlowe.Semantics as MS

data Bounds = Bounds { numParties :: Integer
                     , numChoices :: Integer
                     , numLets :: Integer
                     , numActions :: Integer
                     }

data Mappings = Mappings { partyM :: Numbering MS.Party
                         , choiceM :: Numbering MS.ChoiceId
                         , valueM :: Numbering MS.ValueId }
  deriving (Eq,Ord,Show)

emptyMappings :: Mappings
emptyMappings = Mappings { partyM = emptyNumbering
                         , choiceM = emptyNumbering
                         , valueM = emptyNumbering }

convertParty :: MS.Party -> Mappings -> (Party, Mappings)
convertParty party maps@(Mappings { partyM = partyNumberings }) = (newParty, newMaps)
  where (newParty, newPartyNumberings) = getNumbering party partyNumberings
        newMaps = maps { partyM = newPartyNumberings }


type SlotNumber = Integer
type SSlotNumber = SInteger
type SlotInterval = (SlotNumber, SlotNumber)
type SSlotInterval = STuple SlotNumber SlotNumber
type PubKey = Integer

type Party = PubKey
type SParty = SBV PubKey

type NumChoice = Integer
type NumAccount = Integer
type STimeout = SSlotNumber
type Timeout = SlotNumber

type Money = Integer
type SMoney = SInteger

type ChosenNum = Integer
type SChosenNum = SBV ChosenNum

data ChoiceId = ChoiceId NumChoice Party
  deriving (Eq,Ord,Show,Read)
type NChoiceId = (NumChoice, Party)
type SChoiceId = STuple NumChoice Party

choiceNumber :: ChoiceId -> NumChoice
choiceNumber (ChoiceId numCho _) = numCho

sChoiceId :: NumChoice -> Party -> SChoiceId
sChoiceId c p = ST.tuple (literal c, literal p)

unNestChoiceId :: (NumChoice, Party) -> ChoiceId
unNestChoiceId (numCho, party) = ChoiceId numCho party

literalChoiceId :: ChoiceId -> SChoiceId
literalChoiceId (ChoiceId c p) = sChoiceId c p

newtype OracleId = OracleId PubKey
  deriving (Eq,Ord,Show,Read)

newtype ValueId = ValueId Integer
  deriving (Eq,Ord,Show,Read)
type NValueId = Integer
type SValueId = SInteger

valueIdNumber :: ValueId -> Integer
valueIdNumber (ValueId x) = x

literalValueId :: ValueId -> SValueId
literalValueId (ValueId x) = literal x

unNestValueId :: NValueId -> ValueId
unNestValueId x = ValueId x

data Value = AvailableMoney Party
           | Constant Integer
           | NegValue Value
           | AddValue Value Value
           | SubValue Value Value
           | MulValue Value Value
           | Scale Rational Value
           | ChoiceValue ChoiceId
           | SlotIntervalStart
           | SlotIntervalEnd
           | UseValue ValueId
           | Cond Observation Value Value
--           | OracleValue OracleId Value
  deriving (Eq,Ord,Show,Read)

data Observation = AndObs Observation Observation
                 | OrObs Observation Observation
                 | NotObs Observation
                 | ChoseSomething ChoiceId
                 | ValueGE Value Value
                 | ValueGT Value Value
                 | ValueLT Value Value
                 | ValueLE Value Value
                 | ValueEQ Value Value
                 | TrueObs
                 | FalseObs
--                 | OracleValueProvided OracleId
  deriving (Eq,Ord,Show,Read)

type Bound = (Integer, Integer)

inBounds :: SChosenNum -> [Bound] -> SBool
inBounds num = foldl' (\acc (l, u) -> acc .|| ((num .>= literal l) .&& (num .<= literal u)))
                      sFalse

data Action = Deposit Party Party Value
            | Choice ChoiceId [Bound]
            | Notify Observation
  deriving (Eq,Ord,Show,Read)

data Payee = Account Party
           | Party Party
  deriving (Eq,Ord,Show,Read)

mkSymbolicDatatype ''Payee

data Case = Case Action Contract
  deriving (Eq,Ord,Show,Read)

data Contract = Close
              | Pay Party Payee Value Contract
              | If Observation Contract Contract
              | When [Case] Timeout Contract
              | Let ValueId Value Contract
              | Assert Observation Contract
  deriving (Eq,Ord,Show,Read)

--data State = State { account :: Map AccountId Money
--                   , choice  :: Map ChoiceId ChosenNum
--                   , boundValues :: Map ValueId Integer
--                   , minSlot :: SSlotNumber }
type SState = STuple4 (NIntegerArray)
                      (NIntegerArray)
                      (NIntegerArray)
                      SlotNumber
type State = ( NIntegerArray
             , NIntegerArray
             , NIntegerArray
             , SlotNumber)

emptySState :: Bounds -> SSlotNumber -> SState
emptySState bnds sn = ST.tuple ( IntegerArray.empty (numParties bnds)
                               , IntegerArray.empty (numChoices bnds)
                               , IntegerArray.empty (numLets bnds)
                               , sn)

setAccount :: SState -> SBV NIntegerArray -> SState
setAccount t ac = let (_, ch, va, sl) = ST.untuple t in
                  ST.tuple (ac, ch, va, sl)

setChoice :: SState -> IntegerArray -> SState
setChoice t ch = let (ac, _, va, sl) = ST.untuple t in
                     ST.tuple (ac, ch, va, sl)

setBoundValues :: SState -> IntegerArray -> SState
setBoundValues t va = let (ac, ch, _, sl) = ST.untuple t in
                      ST.tuple (ac, ch, va, sl)

account :: SState -> IntegerArray
account st = ac
  where (ac, _, _, _) = ST.untuple st

choice :: SState -> IntegerArray
choice st = cho
  where (_, cho, _, _) = ST.untuple st

boundValues :: SState -> IntegerArray
boundValues st = bv
  where (_, _, bv, _) = ST.untuple st

minSlot :: SState -> SSlotNumber
minSlot st = ms
  where (_, _, _, ms) = ST.untuple st

setMinSlot :: SState -> SSlotNumber -> SState
setMinSlot st nms = ST.tuple (ac, cho, bv, nms)
  where (ac, cho, bv, _) = ST.untuple st

--data Environment = Environment { slotInterval :: SlotInterval }
type Environment = SlotInterval
type SEnvironment = SSlotInterval

slotInterval :: SEnvironment -> SSlotInterval
slotInterval = id

setSlotInterval :: SEnvironment -> SSlotInterval -> SEnvironment
setSlotInterval _ si = si

sEnvironment :: SSlotInterval -> SEnvironment
sEnvironment si = si

--type SInput = SMaybe (SEither (AccountId, Party, Money) (ChoiceId, ChosenNum))
data Input = IDeposit Party Party Money
           | IChoice NChoiceId ChosenNum
           | INotify
  deriving (Eq,Ord,Show,Read)

mkSymbolicDatatype ''Input

-- TRANSACTION OUTCOMES
--
--type STransactionOutcomes = FSMap Party Money
--type NTransactionOutcomes = NMap Party Money
--
--emptyOutcome :: STransactionOutcomes
--emptyOutcome = FSMap.empty
--
--isEmptyOutcome :: Bounds -> STransactionOutcomes -> SBool
--isEmptyOutcome bnds trOut = FSMap.all (numParties bnds) (.== 0) trOut
--
---- Adds a value to the map of outcomes
--addOutcome :: Bounds -> SParty -> SMoney -> STransactionOutcomes -> STransactionOutcomes
--addOutcome bnds party diffValue trOut =
--    FSMap.insert (numParties bnds) party newValue trOut
--  where
--    newValue = (SM.fromMaybe 0 (FSMap.lookup (numParties bnds) party trOut)) + diffValue
--
---- Add two transaction outcomes together
--combineOutcomes :: Bounds -> STransactionOutcomes -> STransactionOutcomes
--                -> STransactionOutcomes
--combineOutcomes bnds = FSMap.unionWith (numParties bnds) (+)

-- INTERVALS

-- Processing of slot interval
data IntervalError = InvalidInterval SlotInterval
                   | IntervalInPastError SlotNumber SlotInterval
  deriving (Eq,Show)

mkSymbolicDatatype ''IntervalError

data IntervalResult = IntervalTrimmed Environment State
                    | IntervalError NIntervalError
  deriving (Eq,Show)

mkSymbolicDatatype ''IntervalResult

fixInterval :: SSlotInterval -> SState -> SIntervalResult
fixInterval i st =
  ite (h .< l)
      (sIntervalError $ sInvalidInterval i)
      (ite (h .< minSlotV)
           (sIntervalError $ sIntervalInPastError minSlotV i)
           (sIntervalTrimmed env nst))
  where
    (l, h) = ST.untuple i
    minSlotV = minSlot st
    nl = smax l minSlotV
    tInt = ST.tuple (nl, h)
    env = sEnvironment tInt
    nst = st `setMinSlot` nl

-- EVALUATION

-- Evaluate a value
evalValue :: Bounds -> SEnvironment -> SState -> Value -> SInteger
evalValue bnds env state value =
  case value of
    AvailableMoney p -> IntegerArray.findWithDefault 0 p $ account state
    Constant integer         -> literal integer
    NegValue val             -> go val
    AddValue lhs rhs         -> go lhs + go rhs
    SubValue lhs rhs         -> go lhs + go rhs
    MulValue lhs rhs         -> go lhs * go rhs
    Scale s rhs              -> let (n, d) = (numerator s, denominator s) in
                                let nn = go rhs * literal n in
                                let (q, r) = nn `sQuotRem` literal d in
                                ite (abs r * 2 .< literal (abs d)) q (q + signum nn * literal (signum d))
    ChoiceValue (ChoiceId c p) -> SM.maybe (literal 0)
                                           id
                                           (IntegerArray.lookup c $ choice state)
    SlotIntervalStart        -> inStart
    SlotIntervalEnd          -> inEnd
    UseValue (ValueId valId) -> IntegerArray.findWithDefault 0 valId $ boundValues state
    Cond cond thn els        -> ite (evalObservation bnds env state cond) (go thn) (go els)
  where go = evalValue bnds env state
        (inStart, inEnd) = ST.untuple $ slotInterval env

-- Evaluate an observation
evalObservation :: Bounds -> SEnvironment -> SState -> Observation -> SBool
evalObservation bnds env state obs =
  case obs of
    AndObs lhs rhs       -> goObs lhs .&& goObs rhs
    OrObs lhs rhs        -> goObs lhs .|| goObs rhs
    NotObs subObs        -> sNot $ goObs subObs
    ChoseSomething (ChoiceId c p) -> IntegerArray.member c (choice state)
    ValueGE lhs rhs      -> goVal lhs .>= goVal rhs
    ValueGT lhs rhs      -> goVal lhs .> goVal rhs
    ValueLT lhs rhs      -> goVal lhs .< goVal rhs
    ValueLE lhs rhs      -> goVal lhs .<= goVal rhs
    ValueEQ lhs rhs      -> goVal lhs .== goVal rhs
    TrueObs              -> sTrue
    FalseObs             -> sFalse
  where
    goObs = evalObservation bnds env state
    goVal = evalValue bnds env state

-- Obtains the amount of money available an account
moneyInAccount :: IntegerArray -> Party -> SMoney
moneyInAccount accs party = IntegerArray.findWithDefault 0 party accs

-- Sets the amount of money available in an account
updateMoneyInAccount :: IntegerArray -> Party -> SMoney -> IntegerArray
updateMoneyInAccount accs accId mon =
  ite (mon .<= 0)
      (IntegerArray.delete accId accs)
      (IntegerArray.insert accId mon accs)

-- Withdraw up to the given amount of money from an account
-- Return the amount of money withdrawn
withdrawMoneyFromAccount :: IntegerArray -> Party -> SMoney
                         -> STuple Money NIntegerArray
withdrawMoneyFromAccount accs accId mon = ST.tuple (withdrawnMoney, newAcc)
  where
    avMoney = moneyInAccount accs accId
    withdrawnMoney = smin avMoney mon
    newAvMoney = avMoney - withdrawnMoney
    newAcc = updateMoneyInAccount accs accId newAvMoney

-- Add the given amount of money to an accoun (only if it is positive)
-- Return the updated Map
addMoneyToAccount :: IntegerArray -> Party -> SMoney
                  -> IntegerArray
addMoneyToAccount accs accId mon =
  ite (mon .<= 0)
      accs
      (updateMoneyInAccount accs accId newAvMoney)
  where
    avMoney = moneyInAccount accs accId
    newAvMoney = avMoney + mon

data ReduceEffect = ReduceNoEffect
                  | ReduceNormalPay Party Money
  deriving (Eq,Ord,Show,Read)

mkSymbolicDatatype ''ReduceEffect

-- Gives the given amount of money to the given payee
-- Return the appropriate effect and updated Map
giveMoney :: IntegerArray -> Payee -> SMoney
          -> STuple2 NReduceEffect NIntegerArray
giveMoney accs (Party party) mon = ST.tuple ( sReduceNormalPay (literal party) mon
                                            , accs )
giveMoney accs (Account accId) mon = ST.tuple ( sReduceNoEffect
                                              , newAccs )
    where newAccs = addMoneyToAccount accs accId mon


-- REDUCE

data ReduceWarning = ReduceNoWarning
                   | ReduceNonPositivePay Party NPayee Money
                   | ReducePartialPay Party NPayee Money Money
                                    -- ^ src    ^ dest ^ paid ^ expected
                   | ReduceShadowing NValueId Integer Integer
                                     -- oldVal ^  newVal ^
                   | ReduceAssertionFailed
  deriving (Eq,Ord,Show,Read)

mkSymbolicDatatype ''ReduceWarning

data ReduceError = ReduceAmbiguousSlotInterval
  deriving (Eq,Ord,Show,Read)

mkSymbolicDatatype ''ReduceError

data ReduceResult = Reduced NReduceWarning NReduceEffect State
                  | NotReduced
                  | ReduceError NReduceError
  deriving (Eq,Show)

mkSymbolicDatatype ''ReduceResult

data DetReduceResult = DRRContractOver
                     | DRRNoProgressNormal
                     | DRRNoProgressError
                     | DRRProgress Contract Integer -- Integer is num of Payments
  deriving (Eq,Ord,Show,Read)

-- Carry a step of the contract with no inputs
reduce :: SymVal a => Bounds -> SEnvironment -> SState -> Contract
       -> (SReduceResult -> DetReduceResult -> SBV a) -> SBV a
reduce bnds _ state Close f = f sNotReduced $ DRRContractOver
reduce bnds env state (Pay accId payee val nc) f =
  ite (mon .<= 0)
      (f (sReduced (sReduceNonPositivePay (literal accId)
                                          (literal $ nestPayee payee)
                                          mon)
                   sReduceNoEffect state)
         (DRRProgress nc 0))
      (f (sReduced noMonWarn payEffect (state `setAccount` finalAccs)) (DRRProgress nc 1))
  where mon = evalValue bnds env state val
        (paidMon, newAccs) = ST.untuple $
                               withdrawMoneyFromAccount (account state) accId mon
        noMonWarn = ite (paidMon .< mon)
                        (sReducePartialPay (literal accId)
                                           (literal $ nestPayee payee) paidMon mon)
                        (sReduceNoWarning)
        (payEffect, finalAccs) = ST.untuple $ giveMoney newAccs payee paidMon
reduce bnds env state (If obs cont1 cont2) f =
  ite (evalObservation bnds env state obs)
      (f (sReduced sReduceNoWarning sReduceNoEffect state) (DRRProgress cont1 0))
      (f (sReduced sReduceNoWarning sReduceNoEffect state) (DRRProgress cont2 0))
reduce _ env state (When _ timeout c) f =
   ite (endSlot .< (literal timeout))
       (f sNotReduced DRRNoProgressNormal)
       (ite (startSlot .>= (literal timeout))
            (f (sReduced sReduceNoWarning sReduceNoEffect state) $ DRRProgress c 0)
            (f (sReduceError sReduceAmbiguousSlotInterval) $ DRRNoProgressError))
  where (startSlot, endSlot) = ST.untuple $ slotInterval env
reduce bnds env state (Let valId val cont) f =
    f (sReduced warn sReduceNoEffect ns) (DRRProgress cont 0)
  where
    sv = boundValues state
    evVal = evalValue bnds env state val
    nsv = IntegerArray.insert (valueIdNumber valId) evVal sv
    ns = state `setBoundValues` nsv
    warn = SM.maybe (sReduceNoWarning)
                    (\oldVal -> sReduceShadowing lValId oldVal evVal)
                    (IntegerArray.lookup (valueIdNumber valId) sv)
    lValId = literalValueId valId
reduce bnds env state (Assert obs cont) f =
  f (sReduced warn sReduceNoEffect state) (DRRProgress cont 0)
  where warn = ite (evalObservation bnds env state obs) sReduceNoWarning sReduceAssertionFailed

-- REDUCE ALL

data ReduceAllResult = ReducedAll [NReduceWarning] [NReduceEffect] State
                     | ReduceAllError NReduceError
  deriving (Eq,Show)

mkSymbolicDatatype ''ReduceAllResult

data DetReduceAllResult = DRARContractOver
                        | DRARError
                        | DRARNormal Contract Integer -- Integer is num of Payments
  deriving (Eq,Ord,Show,Read)

-- Reduce until it cannot be reduced more

splitReduceResultReduce :: Bounds -> SList NReduceWarning -> SList NReduceEffect
                        -> SSReduceResult
                        -> (SList NReduceWarning, SList NReduceEffect, SState,
                            SReduceError)
splitReduceResultReduce _ wa ef (SSReduced twa tef tsta) =
  ( symCaseReduceWarning
       (\x -> case x of -- Do not add if ReduceNoWarning
                SSReduceNoWarning -> wa
                _ -> twa SL..: wa) twa
  , symCaseReduceEffect
       (\x -> case x of -- Do not add if ReduceNoEffect
                SSReduceNoEffect -> ef
                _ -> tef SL..: ef) tef
  , tsta
  , sReduceAmbiguousSlotInterval {- SNH -})
splitReduceResultReduce bnds _ _ SSNotReduced =
  ([] {- SNH -}, [] {- SNH -}, emptySState bnds 0 {- SNH -}, sReduceAmbiguousSlotInterval {- SNH -})
splitReduceResultReduce bnds _ _ (SSReduceError terr) = ([] {- SNH -}, [] {- SNH -}, emptySState bnds 0{- SNH -}, terr)

reduceAllAux bnds payNum Nothing env sta c wa ef f =
    reduce bnds env sta c contFunc
  where contFunc sr dr =
          (let (nwa, nef, nsta, err) =
                 ST.untuple ((symCaseReduceResult
                                (ST.tuple . (splitReduceResultReduce bnds wa ef))) sr) in
          case dr of
            DRRContractOver -> f (sReducedAll wa ef {- ToDo: extract refunds -} sta)
                                 DRARContractOver
            DRRNoProgressNormal -> f (sReducedAll wa ef sta) $ DRARNormal c 0
            DRRNoProgressError -> f (sReduceAllError err) DRARError
            DRRProgress nc p -> reduceAllAux bnds (payNum + p) Nothing env nsta nc nwa nef f)

reduceAll :: SymVal a => Bounds -> SEnvironment -> SState -> Contract
          -> (SReduceAllResult -> DetReduceAllResult -> SBV a) -> SBV a
reduceAll bnds env sta c f = reduceAllAux bnds 0 Nothing env sta c [] [] f

-- APPLY

data ApplyWarning = ApplyNoWarning
                  | ApplyNonPositiveDeposit Party Party Integer
  deriving (Eq,Ord,Show,Read)

mkSymbolicDatatype ''ApplyWarning

data TransactionWarning = TransactionReduceWarnings [NReduceWarning]
                        | TransactionApplyWarning NApplyWarning

mkSymbolicDatatype ''TransactionWarning


data ApplyError = ApplyNoMatch
  deriving (Eq,Ord,Show,Read)

mkSymbolicDatatype ''ApplyError

data ApplyResult = Applied NApplyWarning State
                 | ApplyError NApplyError
  deriving (Eq,Show)

mkSymbolicDatatype ''ApplyResult

data DetApplyResult = DARNormal Contract
                                Integer -- num of Inputs
                    | DARError

splitReduceAllResult :: Bounds -> SList NTransactionWarning -> SList NReduceEffect
                     -> SSReduceAllResult
                     -> SBV ([NTransactionWarning], [NReduceEffect], State, NReduceError)
splitReduceAllResult bnds wa ef (SSReducedAll twa tef tsta) = ST.tuple $
  (ite (SL.null twa)
       wa
       (wa SL..++ (sTransactionReduceWarnings twa SL..: [])), tef SL..++ ef, tsta, sReduceAmbiguousSlotInterval {- SNH -})
splitReduceAllResult bnds _ _ (SSReduceAllError terr) =
   ST.tuple $ ([] {- SNH -}, [] {- SNH -}, emptySState bnds 0{- SNH -}, terr)

splitReduceAllResultWrap :: Bounds -> SList NTransactionWarning -> SList NReduceEffect
                         -> SReduceAllResult
                         -> SBV ([NTransactionWarning], [NReduceEffect], State, NReduceError)
splitReduceAllResultWrap bnds wa ef sr =
  symCaseReduceAllResult (splitReduceAllResult bnds wa ef) sr

-- Apply a single Input to the contract (assumes the contract is reduced)
applyCases :: SymVal a => Bounds -> SEnvironment -> SState -> SSInput -> [Case] ->
              (SApplyResult -> DetApplyResult -> SBV a) -> SBV a
applyCases bnds env state inp@(SSIDeposit accId1 party1 mon1)
           ((Case (Deposit accId2 party2 val2) nc): t) f =
  ite ((accId1 .== sAccId2) .&& (party1 .== sParty2) .&& (mon1 .== mon2))
      (f (sApplied warning newState) (DARNormal nc 1))
      (applyCases bnds env state inp t f)
  where sAccId2 = literal accId2
        sParty2 = literal party2
        mon2 = evalValue bnds env state val2
        warning = ite (mon2 .> 0)
                      (sApplyNoWarning)
                      (sApplyNonPositiveDeposit party1 sAccId2 mon2)
        accs = account state
        newAccs = addMoneyToAccount accs accId2 mon1
        newState = state `setAccount` newAccs
applyCases bnds env state inp@(SSIChoice choId1 cho1)
           (Case (Choice choId2 bounds2) nc : t) f =
  ite ((choId1 .== sChoId2) .&& (inBounds cho1 bounds2))
      (f (sApplied sApplyNoWarning newState) (DARNormal nc 1))
      (applyCases bnds env state inp t f)
  where newState = state `setChoice`
                     (IntegerArray.insert (choiceNumber choId2) cho1 $ choice state)
        sChoId2 = literalChoiceId choId2
applyCases bnds env state inp@SSINotify (Case (Notify obs) nc : t) f =
  (ite (evalObservation bnds env state obs)
       (f (sApplied sApplyNoWarning state) (DARNormal nc 1))
       (applyCases bnds env state inp t f))
applyCases _ _ _ _ _ f = f (sApplyError sApplyNoMatch) DARError

apply :: SymVal a => Bounds -> SEnvironment -> SState -> SInput -> Contract ->
         (SApplyResult -> DetApplyResult -> SBV a) -> SBV a
apply bnds env state act (When cases _ _ ) f =
  symCaseInput (\x -> applyCases bnds env state x cases f) act
apply _ _ _ _ _ f = f (sApplyError sApplyNoMatch) DARError

-- APPLY ALL

data ApplyAllResult = AppliedAll [NTransactionWarning] [NReduceEffect] State
                    | AAApplyError NApplyError
                    | AAReduceError NReduceError
  deriving (Eq,Show)

mkSymbolicDatatype ''ApplyAllResult

data DetApplyAllResult = DAARNormal Contract
                                    Integer -- num of Payments
                                    Integer -- num of Inputs
                       | DAARError

addIfEffWa :: SList NTransactionWarning -> SSApplyWarning -> SList NTransactionWarning
addIfEffWa nwa SSApplyNoWarning = nwa
addIfEffWa nwa (SSApplyNonPositiveDeposit party accId amount) =
  nwa SL..++ ((sTransactionApplyWarning $ sApplyNonPositiveDeposit party accId amount) SL..: [])

-- Apply a list of Inputs to the contract
applyAllAux :: SymVal a => Integer
            -> Bounds -> Integer -> Integer
            -> SEnvironment -> SState -> Contract -> SList NInput
            -> SList NTransactionWarning -> SList NReduceEffect
            -> (SApplyAllResult -> DetApplyAllResult -> SBV a) -> SBV a
applyAllAux n bnds numPays numInps env state c l wa ef f
  | n >= 0 = reduceAll bnds env state c contFunReduce
  | otherwise = f (sAAReduceError sReduceAmbiguousSlotInterval) DAARError -- SNH
  where contFunReduce sr DRARError =
          let (_, _, _, err) = ST.untuple $ splitReduceAllResultWrap bnds wa ef sr in
          (f (sAAApplyError err) DAARError)
        contFunReduce sr DRARContractOver =
          let (nwa, nef, nstate, _) = ST.untuple $ splitReduceAllResultWrap bnds wa ef sr in
          ite (SL.null l)
              (f (sAppliedAll nwa nef nstate) $ DAARNormal Close numPays numInps)
              (f (sAAApplyError sApplyNoMatch) DAARError)
        contFunReduce sr (DRARNormal nc p) =
          let (nwa, nef, nstate, _) = ST.untuple $ splitReduceAllResultWrap bnds wa ef sr in
          ite (SL.null l)
              (f (sAppliedAll nwa nef nstate) $ DAARNormal nc (p + numPays) numInps)
              (apply bnds env nstate (SL.head l) nc (contFunApply (SL.tail l) nwa nef p))
        contFunApply _ _ _ _ sr DARError =
          f (symCaseApplyResult
               (\x -> case x of
                        SSApplied _ _ -> sAAReduceError sReduceAmbiguousSlotInterval -- SNH
                        SSApplyError err -> sAAApplyError err) sr)
            DAARError
        contFunApply t nwa nef np sr (DARNormal nc ni) =
          (symCaseApplyResult
             (\x -> case x of
                      SSApplied twa nst ->
                          applyAllAux (n - 1) bnds (numPays + np) (numInps + ni)
                                      env nst nc t (symCaseApplyWarning (addIfEffWa nwa) twa) nef f
                      SSApplyError err -> f (sAAApplyError err) DAARError {- SNH -}) sr)

applyAll :: SymVal a => Bounds
         -> SEnvironment -> SState -> Contract -> SList NInput
         -> (SApplyAllResult -> DetApplyAllResult -> SBV a) -> SBV a
applyAll bnds env state c l f =
  applyAllAux (numActions bnds) bnds 0 0 env state c l [] [] f

-- PROCESS

-- List of signatures needed by a transaction
--type STransactionSignatures = FSSet Party
--type NTransactionSignatures = NSet Party

data TransactionError = TEReduceError NReduceError
                      | TEApplyError NApplyError
                      | TEIntervalError NIntervalError
                      | TEUselessTransaction
  deriving (Eq,Show)

mkSymbolicDatatype ''TransactionError

type TransactionEffect = ReduceEffect
type NTransactionEffect = NReduceEffect
type STransactionEffect = SReduceEffect
type SSTransactionEffect = SSReduceEffect

--data Transaction = Transaction { interval :: SSlotInterval
--                               , inputs   :: [SInput] }
--  deriving (Eq,Show)

type STransaction = STuple SlotInterval [NInput]
type NTransaction = (SlotInterval, [NInput])

interval :: STransaction -> SSlotInterval
interval x = let (si, _) = ST.untuple x in si

inputs :: STransaction -> SList NInput
inputs x = let (_, inps) = ST.untuple x in inps

-- Extract necessary signatures from transaction inputs

sFoldl :: SymVal a => SymVal b => Integer
       -> (SBV b -> SBV a -> SBV b) -> SBV b -> SList a -> SBV b
sFoldl inte f acc list
  | inte >= 0 = ite (SL.null list)
                   acc
                   (sFoldl (inte - 1) f (f acc (SL.head list)) (SL.tail list))
  | otherwise = acc

--getSignatures :: Bounds -> Integer -> SList NInput -> STransactionSignatures
--getSignatures bnds numInps =
--  sFoldl numInps (\x y -> symCaseInput (addSig x) y) FSSet.empty
--  where
--    addSig acc (SSIDeposit _ p _) = FSSet.insert (numParties bnds) p acc
--    addSig acc (SSIChoice t _) = let (_, p) = ST.untuple t in
--                                 FSSet.insert (numParties bnds) p acc
--    addSig acc SSINotify = acc
--
--addIfPay :: Bounds -> SSReduceEffect -> STransactionOutcomes -> STransactionOutcomes
--addIfPay bnds (SSReduceNormalPay p m) to = addOutcome bnds p (-m) to
--addIfPay _ _ to = to
--
--addIfDep :: Bounds -> SSInput -> STransactionOutcomes -> STransactionOutcomes
--addIfDep bnds (SSIDeposit _ p m) to = addOutcome bnds p m to
--addIfDep _ _ to = to
--
---- Extract total outcomes from transaction inputs and outputs
--getOutcomesAux :: Bounds -> Integer -> Integer -> SList NReduceEffect -> SList NInput
--               -> STransactionOutcomes -> STransactionOutcomes
--getOutcomesAux bnds numPays numInps eff inp to
--  | numPays >= 0 = ite (SL.null eff)
--                      (getOutcomesAux bnds (-1) numInps [] inp to)
--                      (getOutcomesAux bnds (numPays - 1) numInps
--                                      (SL.tail eff) inp
--                                      (symCaseReduceEffect
--                                         (\oneEff -> addIfPay bnds oneEff to)
--                                         (SL.head eff)))
--  | numInps >= 0 = ite (SL.null inp)
--                      to
--                      (getOutcomesAux bnds (-1) (numInps - 1)
--                                      [] (SL.tail inp)
--                                      (symCaseInput
--                                         (\oneInp -> addIfDep bnds oneInp to)
--                                         (SL.head inp)))
--
--  | otherwise = to -- SNH
--
--getOutcomes :: Bounds -> Integer -> Integer -> SList NReduceEffect -> SList NInput
--            -> STransactionOutcomes
--getOutcomes bnds numPays numInps eff inp =
--  getOutcomesAux bnds numPays numInps eff inp emptyOutcome

data TransactionResult = TransactionProcessed [NTransactionWarning]
                               [NTransactionEffect]
--                               NTransactionSignatures
--                               NTransactionOutcomes
                               State
                   | TransactionError NTransactionError
  deriving (Eq,Show)

mkSymbolicDatatype ''TransactionResult

data DetTransactionResult = DTProcessed Contract
                      | DTError

extractAppliedAll :: SymVal a => Bounds -> SSApplyAllResult
   -> (SBV [NTransactionWarning] -> SBV [NTransactionEffect] -> SBV State -> SBV a)
   -> SBV a
extractAppliedAll _ (SSAppliedAll wa ef nsta) f = f (wa) ef nsta
extractAppliedAll bnds (SSAAApplyError _) f = f [] [] (emptySState bnds 0) -- SNH
extractAppliedAll bnds (SSAAReduceError _) f = f [] [] (emptySState bnds 0) -- SNH

convertTransactionError :: SymVal a => SSApplyAllResult
                        -> (STransactionResult -> DetTransactionResult -> SBV a) -> SBV a
convertTransactionError (SSAppliedAll _ _ _) f =
  f (sTransactionError $ sTEReduceError $ sReduceAmbiguousSlotInterval) DTError -- SNH
convertTransactionError (SSAAApplyError aperr) f =
  f (sTransactionError $ sTEApplyError aperr) DTError
convertTransactionError (SSAAReduceError reerr) f =
  f (sTransactionError $ sTEReduceError reerr) DTError

-- Try to process a transaction
processApplyResult :: SymVal a => Bounds -> STransaction -> SState -> Contract
                   -> (STransactionResult -> DetTransactionResult -> SBV a)
                   -> SApplyAllResult -> DetApplyAllResult
                   -> SBV a
processApplyResult bnds tra sta c f saar (DAARNormal ncon numPays numInps) =
  symCaseApplyAllResult
    (\aar ->
     extractAppliedAll bnds aar
       (\wa ef nsta ->
--        let sigs = getSignatures bnds numInps inps in
--        let outcomes = getOutcomes bnds numPays numInps ef inps in
        if c == ncon
        then (if c /= Close
              then (f (sTransactionError sTEUselessTransaction) DTError)
              else (ite (SL.null $ account sta)
                        (f (sTransactionError sTEUselessTransaction) DTError)
                        (f (sTransactionProcessed wa ef {- sigs outcomes -} nsta) (DTProcessed ncon))))
        else f (sTransactionProcessed wa ef {- sigs outcomes -} nsta) (DTProcessed ncon)))
    saar
  where inps = inputs tra
processApplyResult _ _ _ _ f saar DAARError =
  symCaseApplyAllResult
    (\aar -> convertTransactionError aar f)
    saar

processAux :: SymVal a => Bounds -> STransaction -> SState -> Contract
           -> (STransactionResult -> DetTransactionResult -> SBV a)
           -> SSIntervalResult -> SBV a
processAux bnds tra sta c f (SSIntervalTrimmed env fixSta) =
  applyAll bnds env fixSta c (inputs tra)
           (\sym det -> processApplyResult bnds tra sta c f sym det)
processAux _ _ _ _ f (SSIntervalError intErr) =
  f (sTransactionError $ sTEIntervalError intErr) DTError

process :: SymVal a => Bounds -> STransaction -> SState -> Contract
        -> (STransactionResult -> DetTransactionResult -> SBV a) -> SBV a
process bnds tra sta c f =
  symCaseIntervalResult (\interv -> processAux bnds tra sta c f interv)
                        (fixInterval (interval tra) sta)

extractTransactionResult :: Bounds ->
                        STransactionResult -> ( SList NTransactionWarning
                                              , SList NTransactionEffect
--                                            , STransactionSignatures
--                                            , STransactionOutcomes
                                              , SState)
extractTransactionResult bnds spr =
  ST.untuple (symCaseTransactionResult prCases spr)
  where prCases (SSTransactionProcessed wa ef {- ts to -} nst) = ST.tuple (wa, ef, {- ts, to, -} nst)
        prCases (SSTransactionError _) = ST.tuple ([], [], {- [], [], -} emptySState bnds 0) -- SNH

warningsTraceWBAux :: Integer -> Bounds -> SState -> SList NTransaction -> Contract
                   -> (SList NTransactionWarning)
warningsTraceWBAux inte bnds st transList con
  | inte >= 0 = ite (SL.null transList)
                    []
                    (process bnds (SL.head transList) st con cont)
  | otherwise = [] -- SNH
  where cont spr (DTProcessed ncon) = let (wa, _, {- _, _, -} nst) =
                                             extractTransactionResult bnds spr in
                                      ite (SL.null $ wa)
                                          (warningsTraceWBAux (inte - 1) bnds nst
                                                              (SL.tail transList) ncon)
                                          (ite (SL.null (SL.tail transList))
                                               wa
                                               [])
        cont _ DTError = []

warningsTraceWB :: Bounds -> SSlotNumber -> SList NTransaction -> Contract
                -> (SList NTransactionWarning)
warningsTraceWB bnds sn transList con =
  warningsTraceWBAux (numActions bnds) bnds (emptySState bnds sn) transList con

-- Adaptor functions

type MaxActions = Integer

convertTimeout :: MS.Timeout -> Timeout
convertTimeout (MS.Slot num) = num

convertValId :: MS.ValueId -> Mappings -> (ValueId, Mappings)
convertValId valId maps@(Mappings { valueM = valueNumberings }) =
    (ValueId newValId, mapsWithValId)
  where (newValId, newValueNumberings) = getNumbering valId valueNumberings
        mapsWithValId = maps { valueM = newValueNumberings }

convertChoId :: MS.ChoiceId -> Mappings -> (ChoiceId, Mappings)
convertChoId choId@(MS.ChoiceId _ party) maps =
    (ChoiceId newChoNum newParty, mapsWithParty)
  where choiceNumberings = choiceM maps
        (newChoNum, newChoountNumberings) = getNumbering choId choiceNumberings
        mapsWithChoId = maps { choiceM = newChoountNumberings }
        (newParty, mapsWithParty) = convertParty party mapsWithChoId

convertPayee :: MS.Payee -> Mappings -> (Payee, Mappings)
convertPayee (MS.Account accId) maps = (Account newAccId, mapsWithAccId)
  where (newAccId, mapsWithAccId) = convertParty accId maps
convertPayee (MS.Party party) maps = (Party newParty, mapsWithParty)
  where (newParty, mapsWithParty) = convertParty party maps

convertBound :: MS.Bound -> Bound
convertBound (MS.Bound from to) = (from, to)

convertValue :: MS.Value -> Mappings -> (Value, Mappings)
convertValue (MS.AvailableMoney accId) maps =
    (AvailableMoney newAccId, mapsWithAccId)
  where (newAccId, mapsWithAccId) = convertParty accId maps
convertValue (MS.Constant inte) maps =
    (Constant inte, maps)
convertValue (MS.NegValue val) maps =
    (NegValue newVal, mapsWithVal)
  where (newVal, mapsWithVal) = convertValue val maps
convertValue (MS.AddValue val1 val2) maps =
    (AddValue newVal1 newVal2, mapsWithVal2)
  where (newVal1, mapsWithVal1) = convertValue val1 maps
        (newVal2, mapsWithVal2) = convertValue val2 mapsWithVal1
convertValue (MS.MulValue val1 val2) maps =
    (MulValue newVal1 newVal2, mapsWithVal2)
  where (newVal1, mapsWithVal1) = convertValue val1 maps
        (newVal2, mapsWithVal2) = convertValue val2 mapsWithVal1
convertValue (MS.SubValue val1 val2) maps =
    (SubValue newVal1 newVal2, mapsWithVal2)
  where (newVal1, mapsWithVal1) = convertValue val1 maps
        (newVal2, mapsWithVal2) = convertValue val2 mapsWithVal1
convertValue (MS.ChoiceValue choId) maps =
    (ChoiceValue newChoId, mapsWithChoId)
  where (newChoId, mapsWithChoId) = convertChoId choId maps
convertValue (MS.SlotIntervalStart) maps =
    (SlotIntervalStart, maps)
convertValue (MS.SlotIntervalEnd) maps =
    (SlotIntervalEnd, maps)
convertValue (MS.UseValue valId) maps =
    (UseValue newValId, mapsWithValId)
  where (newValId, mapsWithValId) = convertValId valId maps

convertObservation :: MS.Observation -> Mappings -> (Observation, Mappings)
convertObservation (MS.AndObs obs1 obs2) maps =
    (AndObs newObs1 newObs2, mapsWithObs2)
  where (newObs1, mapsWithObs1) = convertObservation obs1 maps
        (newObs2, mapsWithObs2) = convertObservation obs2 mapsWithObs1
convertObservation (MS.OrObs obs1 obs2) maps =
    (OrObs newObs1 newObs2, mapsWithObs2)
  where (newObs1, mapsWithObs1) = convertObservation obs1 maps
        (newObs2, mapsWithObs2) = convertObservation obs2 mapsWithObs1
convertObservation (MS.NotObs obs) maps =
    (NotObs newObs, mapsWithObs)
  where (newObs, mapsWithObs) = convertObservation obs maps
convertObservation (MS.ChoseSomething choId) maps =
    (ChoseSomething newChoId, mapsWithChoId)
  where (newChoId, mapsWithChoId) = convertChoId choId maps
convertObservation (MS.ValueGE val1 val2) maps =
    (ValueGE newVal1 newVal2, mapsWithVal2)
  where (newVal1, mapsWithVal1) = convertValue val1 maps
        (newVal2, mapsWithVal2) = convertValue val2 mapsWithVal1
convertObservation (MS.ValueGT val1 val2) maps =
    (ValueGT newVal1 newVal2, mapsWithVal2)
  where (newVal1, mapsWithVal1) = convertValue val1 maps
        (newVal2, mapsWithVal2) = convertValue val2 mapsWithVal1
convertObservation (MS.ValueLT val1 val2) maps =
    (ValueLT newVal1 newVal2, mapsWithVal2)
  where (newVal1, mapsWithVal1) = convertValue val1 maps
        (newVal2, mapsWithVal2) = convertValue val2 mapsWithVal1
convertObservation (MS.ValueLE val1 val2) maps =
    (ValueLE newVal1 newVal2, mapsWithVal2)
  where (newVal1, mapsWithVal1) = convertValue val1 maps
        (newVal2, mapsWithVal2) = convertValue val2 mapsWithVal1
convertObservation (MS.ValueEQ val1 val2) maps =
    (ValueEQ newVal1 newVal2, mapsWithVal2)
  where (newVal1, mapsWithVal1) = convertValue val1 maps
        (newVal2, mapsWithVal2) = convertValue val2 mapsWithVal1
convertObservation (MS.TrueObs) maps = (TrueObs, maps)
convertObservation (MS.FalseObs) maps = (FalseObs, maps)

convertAction :: MS.Action -> Mappings -> (Action, Mappings)
convertAction (MS.Deposit accId party value) maps =
    (Deposit newAccId newParty newValue, mapsWithValue)
  where (newAccId, mapsWithAccId) = convertParty accId maps
        (newParty, mapsWithParty) = convertParty party mapsWithAccId
        (newValue, mapsWithValue) = convertValue value mapsWithParty
convertAction (MS.Choice choId bounds) maps =
    (Choice newChoId newBounds, mapsWithChoId)
  where (newChoId, mapsWithChoId) = convertChoId choId maps
        newBounds = map convertBound bounds
convertAction (MS.Notify observation) maps =
    (Notify newObservation, mapsWithObservation)
  where (newObservation, mapsWithObservation) = convertObservation observation maps

convertCaseList :: [MS.Case] -> Mappings -> ([Case], MaxActions, Mappings)
convertCaseList [] maps = ([], 0, maps)
convertCaseList (MS.Case action cont : rest) maps =
    ( (Case newAction newCont : newRest)
    , max (1 + actionsWithCont) actionsWithRest
    , mapsWithRest )
  where (newAction, mapsWithAction) = convertAction action maps
        (newCont, actionsWithCont, mapsWithCont) = convertContract cont mapsWithAction
        (newRest, actionsWithRest, mapsWithRest) = convertCaseList rest mapsWithCont
convertCaseList (MS.MerkleizedCase action _ : rest) maps =
    ( newRest
    , actionsWithRest
    , mapsWithRest )
  where (newAction, mapsWithAction) = convertAction action maps
        (newRest, actionsWithRest, mapsWithRest) = convertCaseList rest mapsWithAction

convertContract :: MS.Contract -> Mappings -> (Contract, MaxActions, Mappings)
convertContract MS.Close maps = (Close, 0, maps)
convertContract (MS.Pay accId payee value cont) maps =
    (Pay newAccId newPayee newValue newCont, actionsWithCont, mapsWithContract)
  where (newAccId, mapsWithAccId) = convertParty accId maps
        (newPayee, mapsWithPayee) = convertPayee payee mapsWithAccId
        (newValue, mapsWithValue) = convertValue value mapsWithPayee
        (newCont, actionsWithCont, mapsWithContract) = convertContract cont mapsWithValue
convertContract (MS.If obs cont1 cont2) maps =
    (If newObs newCont1 newCont2, max actionsWithCont1 actionsWithCont2, mapsWithCont2)
  where (newObs, mapsWithObs) = convertObservation obs maps
        (newCont1, actionsWithCont1, mapsWithCont1) = convertContract cont1 mapsWithObs
        (newCont2, actionsWithCont2, mapsWithCont2) = convertContract cont2 mapsWithCont1
convertContract (MS.When caseList timeout cont) maps =
    ( When newCaseList newTimeout newCont
    , max actionsWithCaseList actionsWithCont
    , mapsWithCont)
  where (newCaseList, actionsWithCaseList, mapsWithCaseList) = convertCaseList caseList maps
        newTimeout = convertTimeout timeout
        (newCont, actionsWithCont, mapsWithCont) = convertContract cont mapsWithCaseList
convertContract (MS.Let valId value cont) maps =
    (Let newValId newValue newCont, actionsWithCont, mapsWithContract)
  where (newValId, mapsWithValId) = convertValId valId maps
        (newValue, mapsWithValue) = convertValue value mapsWithValId
        (newCont, actionsWithCont, mapsWithContract) = convertContract cont mapsWithValue
convertContract (MS.Assert obs cont) maps =
    (Assert newObs newCont, actionsWithCont, mapsWithContract)
  where (newObs, mapsWithObs) = convertObservation obs maps
        (newCont, actionsWithCont, mapsWithContract) = convertContract cont mapsWithObs

convertContractBase :: MS.Contract -> (Contract, MaxActions, Mappings)
convertContractBase c = convertContract c emptyMappings

extractBounds :: MaxActions -> Mappings -> Bounds
extractBounds maxActions maps =
  Bounds { numParties = numberOfLabels (partyM maps)
         , numChoices = numberOfLabels (choiceM maps)
         , numLets = numberOfLabels (valueM maps)
         , numActions = maxActions }

revertParty :: Party -> Mappings -> MS.PubKey
revertParty party maps = getLabel party (partyM maps)

revertMoney :: Money -> MS.Ada
revertMoney mon = MS.Lovelace { MS.getLovelace = mon }

revertSlotNum :: SlotNumber -> MS.Slot
revertSlotNum sn = MS.Slot { MS.getSlot = sn }

revertInterval :: SlotInterval -> MS.SlotInterval
revertInterval (snl, snh) = MS.SlotInterval (revertSlotNum snl) (revertSlotNum snh)

revertChoId :: ChoiceId -> Mappings -> MS.ChoiceId
revertChoId (ChoiceId choId _) maps = getLabel choId (choiceM maps)

revertValId :: ValueId -> Mappings -> MS.ValueId
revertValId (ValueId valId) maps = getLabel valId (valueM maps)

revertInputContent :: Input -> Mappings -> MS.InputContent
revertInputContent (IDeposit accId party mon) maps = MS.IDeposit newAccId newParty newMon
  where newAccId = revertParty accId maps
        newParty = revertParty party maps
        newMon = revertMoney mon
revertInputContent (IChoice choId chosenNum) maps = MS.IChoice newChoId chosenNum
  where newChoId = revertChoId (unNestChoiceId choId) maps
revertInputContent INotify _ = MS.INotify

revertTransactionList :: [NTransaction] -> Mappings -> [MS.TransactionInput]
revertTransactionList list maps =
  [MS.TransactionInput { MS.txInterval = revertInterval slotInter
                       , MS.txInputs = map ((MS.NormalInput . flip revertInputContent maps) . unNestInput) nInput }
   | (slotInter, nInput) <- list]

revertPayee :: Payee -> Mappings -> MS.Payee
revertPayee (Account accId) maps = MS.Account (revertParty accId maps)
revertPayee (Party party) maps = MS.Party (revertParty party maps)

revertReduceWarningList :: ReduceWarning -> Mappings -> MS.ReduceWarning
revertReduceWarningList ReduceNoWarning _ = MS.ReduceNoWarning
revertReduceWarningList (ReduceNonPositivePay accId payee inte) maps =
     MS.ReduceNonPositivePay newAccId newPayee inte
  where newAccId = revertParty accId maps
        newPayee = revertPayee (unNestPayee payee) maps
revertReduceWarningList (ReducePartialPay accId payee mon1 mon2) maps =
     MS.ReducePartialPay newAccId newPayee newMon1 newMon2
  where newAccId = revertParty accId maps
        newPayee = revertPayee (unNestPayee payee) maps
        newMon1 = revertMoney mon1
        newMon2 = revertMoney mon2
revertReduceWarningList (ReduceShadowing valId int1 int2) maps =
     MS.ReduceShadowing newValId int1 int2
  where newValId = revertValId (unNestValueId valId) maps
revertReduceWarningList ReduceAssertionFailed maps = MS.ReduceAssertionFailed

revertTransactionWarningList :: TransactionWarning -> Mappings -> [MS.TransactionWarning]
revertTransactionWarningList (TransactionReduceWarnings warningList) maps =
  MS.convertReduceWarnings $ map (((flip revertReduceWarningList) maps) . unNestReduceWarning) warningList
revertTransactionWarningList (TransactionApplyWarning applyWarning) maps =
  case unNestApplyWarning applyWarning of
    (ApplyNonPositiveDeposit party accId amount) ->
       [MS.TransactionNonPositiveDeposit (revertParty party maps)
                                         (revertParty accId maps)
                                         amount]
    ApplyNoWarning -> error "ApplyNoWarning in result"

snLabel, transListLabel :: String
snLabel = "sn"
transListLabel = "transList"

extractCounterExample :: SMTModel -> Mappings
                      -> (SSlotNumber -> SList NTransaction -> SList NTransactionWarning)
                      -> (MS.Slot, [MS.TransactionInput], [MS.TransactionWarning])
extractCounterExample smtModel maps func = ( revertSlotNum slotNum
                                           , revertTransactionList transList maps
                                           , revertAllWarnings )
  where assocs = modelAssocs smtModel
        (Just cvSlotNum) = lookup snLabel assocs
        (Just cvTransList) = lookup transListLabel assocs
        slotNum = fromCV cvSlotNum
        transList = fromCV cvTransList
        Just warningList = unliteral (func (literal slotNum) (literal transList))
        revertAllWarnings = concat $ map (\x -> revertTransactionWarningList
                                                  (unNestTransactionWarning x) maps) warningList

warningsTrace :: MS.Contract
              -> IO (Either (ThmResult)
                            (Maybe ( MS.Slot
                                   , [MS.TransactionInput]
                                   , [MS.TransactionWarning] )))
warningsTrace con =
    do thmRes@(ThmResult result) <- satCommand
       return (case result of
                 Unsatisfiable _ _ -> Right Nothing
                 Satisfiable _ smtModel ->
                    Right (Just (extractCounterExample smtModel maps
                                   warningsFunc))
                 _ -> Left thmRes)
  where (convCont, maxActs, maps) = convertContractBase con
        bnds = extractBounds maxActs maps
        warningsFunc sn transList = warningsTraceWB bnds sn transList convCont
        satCommand = proveWith (z3 {validateModel = True})
                               (forAll [snLabel, transListLabel]
                                   (\sn transList ->
                                       (SL.length transList .<= literal (maxActs + 1)) .&& (sn .>= literal 0) .=>
                                       SL.null (warningsFunc sn transList)))

