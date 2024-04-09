// SPDX-License-Identifier: MIT
// OpenZeppelin Contracts (last updated v5.0.0) (governance/utils/Votes.sol)
pragma solidity ^0.8.20;

import {IERC5805Modified} from "src/IERC5805Modified.sol";
import {ContextUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/ContextUpgradeable.sol";
import {NoncesUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/NoncesUpgradeable.sol";
import {EIP712Upgradeable} from "@openzeppelin/contracts-upgradeable/utils/cryptography/EIP712Upgradeable.sol";
import {Checkpoints} from "@openzeppelin/contracts/utils/structs/Checkpoints.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {Time} from "@openzeppelin/contracts/utils/types/Time.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {PartialDelegation} from "src/IVotesPartialDelegation.sol";
import {console2} from "forge-std/console2.sol";

/**
 * @dev This is a base abstract contract that tracks voting units, which are a measure of voting power that can be
 * transferred, and provides a system of vote delegation, where an account can delegate its voting units to a sort of
 * "representative" that will pool delegated voting units from different accounts and can then use it to vote in
 * decisions. In fact, voting units _must_ be delegated in order to count as actual votes, and an account has to
 * delegate those votes to itself if it wishes to participate in decisions and does not have a trusted representative.
 *
 * This contract is often combined with a token contract such that voting units correspond to token units. For an
 * example, see {ERC721Votes}.
 *
 * The full history of delegate votes is tracked on-chain so that governance protocols can consider votes as distributed
 * at a particular block number to protect against flash loans and double voting. The opt-in delegate system makes the
 * cost of this history tracking optional.
 *
 * When using this module the derived contract must implement {_getVotingUnits} (for example, make it return
 * {ERC721-balanceOf}), and can use {_transferVotingUnits} to track a change in the distribution of those units (in the
 * previous example, it would be included in {ERC721-_update}).
 */
abstract contract VotesPartialDelegationUpgradeable is
  Initializable,
  ContextUpgradeable,
  EIP712Upgradeable,
  NoncesUpgradeable,
  IERC5805Modified
{
  using Checkpoints for Checkpoints.Trace208;

  bytes32 private constant DELEGATION_TYPEHASH = keccak256("Delegation(address delegatee,uint256 nonce,uint256 expiry)");
  bytes32 public constant PARTIAL_DELEGATION_TYPEHASH =
    keccak256("PartialDelegation(PartialDelegation[] delegations,uint256 nonce,uint256 expiry)");
  uint256 public constant MAX_PARTIAL_DELEGATIONS = 100;
  uint96 public constant DENOMINATOR = 10_000;

  enum Op {
    ADD,
    SUBTRACT
  }

  struct DelegationAdjustment {
    address _delegatee;
    uint208 _amount;
    Op _op;
  }

  /// @custom:storage-location erc7201:openzeppelin.storage.Votes
  struct VotesPartialDelegationStorage {
    mapping(address account => PartialDelegation[]) _delegatees;
    mapping(address delegatee => Checkpoints.Trace208) _delegateCheckpoints;
    Checkpoints.Trace208 _totalCheckpoints;
  }

  // keccak256(abi.encode(uint256(keccak256("openzeppelin.storage.VotesPartialDelegation")) - 1))
  // &~bytes32(uint256(0xff))
  bytes32 private constant VotesPartialDelegationStorageLocation =
    0x12a728d6ef7084b9d775fe05520ff4e00000bc23996fe81cefc12739f2cd9000;

  function _getVotesPartialDelegationStorage() private pure returns (VotesPartialDelegationStorage storage $) {
    assembly {
      $.slot := VotesPartialDelegationStorageLocation
    }
  }

  /**
   * @dev The clock was incorrectly modified.
   */
  error ERC6372InconsistentClock();

  /**
   * @dev Lookup to future votes is not available.
   */
  error ERC5805FutureLookup(uint256 timepoint, uint48 clock);

  function __VotesPartialDelegation_init() internal onlyInitializing {}

  function __VotesPartialDelegation_init_unchained() internal onlyInitializing {}
  /**
   * @dev Clock used for flagging checkpoints. Can be overridden to implement timestamp based
   * checkpoints (and voting), in which case {CLOCK_MODE} should be overridden as well to match.
   */

  function clock() public view virtual returns (uint48) {
    return Time.blockNumber();
  }

  /**
   * @dev Machine-readable description of the clock as specified in EIP-6372.
   */
  // solhint-disable-next-line func-name-mixedcase
  function CLOCK_MODE() public view virtual returns (string memory) {
    // Check that the clock was not modified
    if (clock() != Time.blockNumber()) {
      revert ERC6372InconsistentClock();
    }
    return "mode=blocknumber&from=default";
  }

  /**
   * @dev Returns the current amount of votes that `account` has.
   */
  function getVotes(address account) public view virtual returns (uint256) {
    VotesPartialDelegationStorage storage $ = _getVotesPartialDelegationStorage();
    return $._delegateCheckpoints[account].latest();
  }

  /**
   * @dev Returns the amount of votes that `account` had at a specific moment in the past. If the `clock()` is
   * configured to use block numbers, this will return the value at the end of the corresponding block.
   *
   * Requirements:
   *
   * - `timepoint` must be in the past. If operating using block numbers, the block must be already mined.
   */
  function getPastVotes(address account, uint256 timepoint) public view virtual returns (uint256) {
    VotesPartialDelegationStorage storage $ = _getVotesPartialDelegationStorage();
    uint48 currentTimepoint = clock();
    if (timepoint >= currentTimepoint) {
      revert ERC5805FutureLookup(timepoint, currentTimepoint);
    }
    return $._delegateCheckpoints[account].upperLookupRecent(SafeCast.toUint48(timepoint));
  }

  /**
   * @dev Returns the total supply of votes available at a specific moment in the past. If the `clock()` is
   * configured to use block numbers, this will return the value at the end of the corresponding block.
   *
   * NOTE: This value is the sum of all available votes, which is not necessarily the sum of all delegated votes.
   * Votes that have not been delegated are still part of total supply, even though they would not participate in a
   * vote.
   *
   * Requirements:
   *
   * - `timepoint` must be in the past. If operating using block numbers, the block must be already mined.
   */
  function getPastTotalSupply(uint256 timepoint) public view virtual returns (uint256) {
    VotesPartialDelegationStorage storage $ = _getVotesPartialDelegationStorage();
    uint48 currentTimepoint = clock();
    if (timepoint >= currentTimepoint) {
      revert ERC5805FutureLookup(timepoint, currentTimepoint);
    }
    return $._totalCheckpoints.upperLookupRecent(SafeCast.toUint48(timepoint));
  }

  /**
   * @dev Returns the current total supply of votes.
   */
  function _getTotalSupply() internal view virtual returns (uint256) {
    VotesPartialDelegationStorage storage $ = _getVotesPartialDelegationStorage();
    return $._totalCheckpoints.latest();
  }

  /**
   * @dev Returns the delegate that `account` has chosen.
   */
  function delegates(address account) public view virtual returns (PartialDelegation[] memory) {
    VotesPartialDelegationStorage storage $ = _getVotesPartialDelegationStorage();
    return $._delegatees[account];
  }

  /**
   * @dev Delegates votes from the sender to `delegatee`.
   */
  function delegate(address delegatee) public virtual {
    address account = _msgSender();
    PartialDelegation[] memory delegations = new PartialDelegation[](1);
    delegations[0] = PartialDelegation(delegatee, DENOMINATOR);
    _delegate(account, delegations);
  }

  /**
   * @dev Delegates votes from the sender to each `PartialDelegation._delegatee`.
   */
  function delegate(PartialDelegation[] calldata _partialDelegations) public virtual {
    address account = _msgSender();
    _delegate(account, _partialDelegations);
  }

  /**
   * @notice Delegates votes from signer to `delegatee`.
   * @custom:legacy
   */
  function delegateBySig(address delegatee, uint256 nonce, uint256 expiry, uint8 v, bytes32 r, bytes32 s)
    public
    virtual
  {
    if (block.timestamp > expiry) {
      revert VotesExpiredSignature(expiry);
    }
    address signer =
      ECDSA.recover(_hashTypedDataV4(keccak256(abi.encode(DELEGATION_TYPEHASH, delegatee, nonce, expiry))), v, r, s);
    _useCheckedNonce(signer, nonce);
    PartialDelegation[] memory _partialDelegations = new PartialDelegation[](1);
    _partialDelegations[0] = PartialDelegation(delegatee, DENOMINATOR);
    _delegate(signer, _partialDelegations);
  }

  /**
   * @dev Delegates votes from signer to `delegatee`.
   */
  function delegateOnBehalf(
    PartialDelegation[] memory _partialDelegations,
    uint256 _nonce,
    uint256 _expiry,
    bytes calldata _signature
  ) public virtual {
    if (block.timestamp > _expiry) {
      revert VotesExpiredSignature(_expiry);
    }
    // TODO: prefer this, or isValidSignatureNow?
    address _signer = ECDSA.recover(
      _hashTypedDataV4(keccak256(abi.encode(PARTIAL_DELEGATION_TYPEHASH, _partialDelegations, _nonce, _expiry))),
      _signature
    );
    _useCheckedNonce(_signer, _nonce);
    _delegate(_signer, _partialDelegations);
  }

  /**
   * @dev Delegate all of `account`'s voting units to delegates specified in `PartialDelegations`.
   *
   * Emits events {IVotes-DelegateChanged} and {IVotes-DelegateVotesChanged}.
   */
  function _delegate(address _account, PartialDelegation[] memory _newDelegations) internal virtual {
    if (_newDelegations.length > MAX_PARTIAL_DELEGATIONS) {
      revert("VotesPartialDelegation: too many partial delegations");
    }
    VotesPartialDelegationStorage storage $ = _getVotesPartialDelegationStorage();
    // (optional) prune and sum _old and _new
    PartialDelegation[] memory _oldDelegations = delegates(_account);
    if (_oldDelegations.length > 0) {
      DelegationAdjustment[] memory _old =
        _calculateWeightDistribution(_oldDelegations, _getVotingUnits(_account), Op.SUBTRACT);
      _createDelegateCheckpoints(_old);
    }

    DelegationAdjustment[] memory _new =
      _calculateWeightDistribution(_newDelegations, _getVotingUnits(_account), Op.ADD);
    _createDelegateCheckpoints(_new);

    // Replace the old delegatees with the new ones
    uint256 _oldDelegateLength = _oldDelegations.length;
    address _lastDelegatee;
    for (uint256 i = 0; i < _newDelegations.length; i++) {
      if (i == 0 && _newDelegations[i]._delegatee == address(0)) {
        // zero delegation is allowed if in 0th position
      } else if (_newDelegations[i]._delegatee <= _lastDelegatee) {
        revert("VotesPartialDelegation: delegatees must be sorted with no duplicates");
      }
      if (i < _oldDelegateLength) {
        $._delegatees[_account][i] = _newDelegations[i];
      } else {
        $._delegatees[_account].push(_newDelegations[i]);
      }
      // keep track of last delegatee to ensure ordering / uniqueness
      _lastDelegatee = _newDelegations[i]._delegatee;
      emit DelegateChanged(_account, _newDelegations[i]._delegatee, _newDelegations[i]._numerator);
    }
    if (_oldDelegateLength > _newDelegations.length) {
      for (uint256 i = _newDelegations.length; i < _oldDelegateLength; i++) {
        $._delegatees[_account].pop();
      }
    }
  }

  /**
   * @dev Transfers, mints, or burns voting units. To register a mint, `from` should be zero. To register a burn, `to`
   * should be zero. Total supply of voting units will be adjusted with mints and burns.
   */
  function _transferVotingUnits(address from, address to, uint256 amount) internal virtual {
    if (from == to) {
      return;
    }
    VotesPartialDelegationStorage storage $ = _getVotesPartialDelegationStorage();
    if (from == address(0)) {
      _push($._totalCheckpoints, _add, SafeCast.toUint208(amount));
    }
    if (to == address(0)) {
      _push($._totalCheckpoints, _subtract, SafeCast.toUint208(amount));
    }
    // This case is more complicated than a delegation.
    DelegationAdjustment[] memory _delegationAdjustments = _calculateDelegateVoteAdjustments(from, to, amount);
    if (_delegationAdjustments.length > 0) {
      _createDelegateCheckpoints(_delegationAdjustments);
    }
  }

  function _calculateDelegateVoteAdjustments(address from, address to, uint256 amount)
    internal
    virtual
    returns (DelegationAdjustment[] memory)
  {
    VotesPartialDelegationStorage storage $ = _getVotesPartialDelegationStorage();
    DelegationAdjustment[] memory _delegationAdjustments =
      new DelegationAdjustment[]($._delegatees[from].length + $._delegatees[to].length);
    if ($._delegatees[from].length > 0) {
      // TODO: maybe don't overload the use of DelegationAdjustment
      // We don't use the add/subtract flags here
      DelegationAdjustment[] memory _from =
        _calculateWeightDistribution($._delegatees[from], _getVotingUnits(from), Op.ADD /* unused */ );
      DelegationAdjustment[] memory _fromNew =
        _calculateWeightDistribution($._delegatees[from], _getVotingUnits(from) - amount, Op.ADD /* unused */ );

      for (uint256 i = 0; i < _from.length; i++) {
        // TODO: determine if remainder treatment is necessary (test says no, so we remove)
        // if (i != _from.length - 1) {
        _delegationAdjustments[i] = DelegationAdjustment({
          _delegatee: $._delegatees[from][i]._delegatee,
          _amount: _from[i]._amount - _fromNew[i]._amount,
          _op: Op.SUBTRACT
        });
        // } else {
        //   // special treatment of remainder delegatee
        //   Op _op;
        //   uint208 _amount;
        //   if (_fromNew[i]._amount == _from[i]._amount) {
        //     continue;
        //   } else if (_fromNew[i]._amount > _from[i]._amount) {
        //     _op = Op.ADD;
        //     _amount = _fromNew[i]._amount - _from[i]._amount;
        //   } else {
        //     _op = Op.SUBTRACT;
        //     _amount = _from[i]._amount - _fromNew[i]._amount;
        //   }
        //   _delegationAdjustments[i] =
        //     DelegationAdjustment({_delegatee: $._delegatees[from][i]._delegatee, _amount: _amount, _op: _op});
        // }
      }
    }
    if ($._delegatees[to].length > 0) {
      DelegationAdjustment[] memory _to =
        _calculateWeightDistribution($._delegatees[to], _getVotingUnits(to), Op.ADD /* unused */ );
      DelegationAdjustment[] memory _toNew =
        _calculateWeightDistribution($._delegatees[to], amount + _getVotingUnits(to), Op.ADD /* unused */ );

      for (uint256 i = 0; i < _to.length; i++) {
        if (i < _to.length - 1) {
          _delegationAdjustments[i + $._delegatees[from].length] = (
            DelegationAdjustment({
              _delegatee: $._delegatees[to][i]._delegatee,
              _amount: _toNew[i]._amount - _to[i]._amount,
              _op: Op.ADD
            })
          );
        } else {
          // special treatment of remainder delegatee
          Op _op;
          uint208 _amount;
          if (_toNew[i]._amount == _to[i]._amount) {
            continue;
          } else if (_toNew[i]._amount > _to[i]._amount) {
            _op = Op.ADD;
            _amount = _toNew[i]._amount - _to[i]._amount;
          } else {
            _op = Op.SUBTRACT;
            _amount = _to[i]._amount - _toNew[i]._amount;
          }
          _delegationAdjustments[i + $._delegatees[from].length] =
            (DelegationAdjustment({_delegatee: $._delegatees[to][i]._delegatee, _amount: _amount, _op: _op}));
        }
      }
    }
    // TODO: prune zero adjustments, sum all adjustments per delegate
    return _delegationAdjustments;
  }

  /// @notice Internal helper that creates a delegatee checkpoint per DelegationAdjustment.
  /// @dev Prefer a _delegationAdjustments array that's already totaled and pruned.
  /// totaled: all additions and subtractions should be summed per delegate
  /// pruned: all zero adjustments should be removed
  function _createDelegateCheckpoints(DelegationAdjustment[] memory _delegationAdjustments) internal {
    VotesPartialDelegationStorage storage $ = _getVotesPartialDelegationStorage();
    for (uint256 i = 0; i < _delegationAdjustments.length; i++) {
      // if (_delegationAdjustments[i]._delegatee == address(0)) {
      //   _push(
      //     $._totalCheckpoints, _op(_delegationAdjustments[i]._op),
      // SafeCast.toUint208(_delegationAdjustments[i]._amount)
      //   );
      // } else {
      (uint256 oldValue, uint256 newValue) = _push(
        $._delegateCheckpoints[_delegationAdjustments[i]._delegatee],
        _op(_delegationAdjustments[i]._op),
        SafeCast.toUint208(_delegationAdjustments[i]._amount)
      );
      emit DelegateVotesChanged(_delegationAdjustments[i]._delegatee, oldValue, newValue);
      // }
    }
  }

  /// @notice Internal helper to calculate vote weights from a list of delegations.
  /// It verifies that the sum of the numerators is less than or equal to DENOMINATOR.
  function _calculateWeightDistribution(PartialDelegation[] memory _delegations, uint256 _amount, Op _op)
    internal
    pure
    returns (DelegationAdjustment[] memory)
  {
    DelegationAdjustment[] memory _delegationAdjustments = new DelegationAdjustment[](_delegations.length);
    uint256 _totalVotes = 0;
    uint256 _totalNumerator = 0;
    for (uint256 i = 0; i < _delegations.length; i++) {
      if (_delegations[i]._numerator == 0) {
        revert("VotesPartialDelegation: invalid numerator of 0");
      }
      _delegationAdjustments[i] = DelegationAdjustment(
        _delegations[i]._delegatee, uint208(_amount * _delegations[i]._numerator / DENOMINATOR), _op
      );
      _totalNumerator += _delegations[i]._numerator;
      _totalVotes += _delegationAdjustments[i]._amount;
    }
    if (_totalNumerator > DENOMINATOR) {
      revert("VotesPartialDelegation: delegation numerators sum to more than DENOMINATOR");
    }
    // assign remaining weight to last delegatee
    // TODO: determine correct behavior
    if (_totalVotes < _amount) {
      _delegationAdjustments[_delegations.length - 1]._amount += uint208(_amount - _totalVotes);
    }

    return _delegationAdjustments;
  }

  /**
   * @dev Get number of checkpoints for `account`.
   */
  function _numCheckpoints(address account) internal view virtual returns (uint32) {
    VotesPartialDelegationStorage storage $ = _getVotesPartialDelegationStorage();
    return SafeCast.toUint32($._delegateCheckpoints[account].length());
  }

  /**
   * @dev Get the `pos`-th checkpoint for `account`.
   */
  function _checkpoints(address account, uint32 pos) internal view virtual returns (Checkpoints.Checkpoint208 memory) {
    VotesPartialDelegationStorage storage $ = _getVotesPartialDelegationStorage();
    return $._delegateCheckpoints[account].at(pos);
  }

  function _push(
    Checkpoints.Trace208 storage store,
    function(uint208, uint208) view returns (uint208) op,
    uint208 delta
  ) private returns (uint208, uint208) {
    return store.push(clock(), op(store.latest(), delta));
  }

  function _add(uint208 a, uint208 b) private pure returns (uint208) {
    return a + b;
  }

  function _subtract(uint208 a, uint208 b) private pure returns (uint208) {
    return a - b;
  }

  function _op(Op op) internal pure returns (function(uint208, uint208) view returns (uint208)) {
    return op == Op.ADD ? _add : _subtract;
  }

  /**
   * @dev Must return the voting units held by an account.
   */
  function _getVotingUnits(address) internal view virtual returns (uint256);
}