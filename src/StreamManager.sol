// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";

/// @title StreamManager
/// @notice Continuous (Sablier-style) ERC20 payment streams with a linear release curve
///         and an optional cliff. A single contract multiplexes many id-keyed streams
///         for payroll, grants and vesting-as-a-stream use cases.
/// @dev A bounded protocol fee is skimmed once, at stream creation. Deposits are
///      fee-on-transfer safe (the streamed principal is credited from tokens actually
///      received). All value-moving functions follow checks-effects-interactions and
///      are reentrancy guarded. No admin path can seize stream funds.
contract StreamManager is ReentrancyGuard, Ownable {
    using SafeERC20 for IERC20;
    using SafeCast for uint256;

    // -------------------------------------------------------------------------
    // Types
    // -------------------------------------------------------------------------

    /// @notice Lifecycle status of a stream.
    enum Status {
        Pending, // start time not yet reached
        Streaming, // active, principal partially released
        Settled, // fully released (>= end) but not fully withdrawn
        Canceled, // canceled by sender or recipient; balances settled
        Depleted // principal fully withdrawn

    }

    /// @param sender The creator/funder, and refund beneficiary on cancel.
    /// @param recipient The stream beneficiary (mutable via transferRecipient).
    /// @param token The streamed ERC20.
    /// @param deposit The streamed principal (total received minus the creation fee).
    /// @param withdrawn Cumulative amount already withdrawn to the recipient side.
    /// @param refunded Amount returned to the sender on cancel (unstreamed remainder).
    /// @param startTime Unix time the stream begins releasing.
    /// @param cliffTime Unix time before which nothing is withdrawable; 0 means no cliff.
    /// @param endTime Unix time at which the principal is fully released.
    /// @param cancelable Whether the stream may be canceled.
    /// @param canceled Whether the stream has been canceled.
    struct Stream {
        address sender;
        address recipient;
        address token;
        uint128 deposit;
        uint128 withdrawn;
        uint128 refunded;
        uint40 startTime;
        uint40 cliffTime;
        uint40 endTime;
        bool cancelable;
        bool canceled;
    }

    // -------------------------------------------------------------------------
    // Constants & storage
    // -------------------------------------------------------------------------

    /// @notice Basis-points denominator (100%).
    uint256 public constant MAX_BPS = 10_000;

    /// @notice Hard cap on the protocol fee (10%). feeBps can never exceed this.
    uint256 public constant MAX_FEE_BPS = 1_000;

    /// @notice Address that receives the protocol fee skimmed at stream creation.
    address public feeRecipient;

    /// @notice Protocol fee in basis points, applied once at creation. <= MAX_FEE_BPS.
    uint256 public feeBps;

    /// @notice Id of the next stream to be created (ids start at 1).
    uint256 public nextStreamId;

    /// @dev streamId => stream data.
    mapping(uint256 => Stream) private _streams;

    /// @dev streamId => address approved to withdraw on the recipient's behalf.
    mapping(uint256 => address) private _approved;

    // -------------------------------------------------------------------------
    // Events
    // -------------------------------------------------------------------------

    event StreamCreated(
        uint256 indexed streamId,
        address indexed sender,
        address indexed recipient,
        address token,
        uint256 deposit,
        uint256 fee,
        uint40 startTime,
        uint40 cliffTime,
        uint40 endTime,
        bool cancelable
    );
    event WithdrawFromStream(uint256 indexed streamId, address indexed to, address indexed caller, uint256 amount);
    event CancelStream(
        uint256 indexed streamId,
        address indexed sender,
        address indexed recipient,
        uint256 recipientAmount,
        uint256 senderRefund
    );
    event TransferRecipient(uint256 indexed streamId, address indexed oldRecipient, address indexed newRecipient);
    event ApproveWithdrawer(uint256 indexed streamId, address indexed spender);
    event SetFeeRecipient(address indexed oldRecipient, address indexed newRecipient);
    event SetFeeBps(uint256 oldFeeBps, uint256 newFeeBps);

    // -------------------------------------------------------------------------
    // Errors
    // -------------------------------------------------------------------------

    error ZeroAddress();
    error ZeroAmount();
    error FeeTooHigh(uint256 feeBps, uint256 maxFeeBps);
    error InvalidTimeRange(uint40 startTime, uint40 endTime);
    error InvalidCliff(uint40 startTime, uint40 cliffTime, uint40 endTime);
    error NothingReceived();
    error StreamNull(uint256 streamId);
    error Unauthorized(uint256 streamId, address caller);
    error Overdraw(uint256 streamId, uint256 requested, uint256 withdrawable);
    error NotCancelable(uint256 streamId);
    error AlreadyCanceled(uint256 streamId);

    // -------------------------------------------------------------------------
    // Constructor
    // -------------------------------------------------------------------------

    /// @param initialOwner Protocol owner (fee configuration only).
    /// @param initialFeeRecipient Recipient of creation fees.
    /// @param initialFeeBps Initial protocol fee, <= MAX_FEE_BPS.
    constructor(address initialOwner, address initialFeeRecipient, uint256 initialFeeBps) Ownable(initialOwner) {
        if (initialFeeRecipient == address(0)) revert ZeroAddress();
        if (initialFeeBps > MAX_FEE_BPS) revert FeeTooHigh(initialFeeBps, MAX_FEE_BPS);
        feeRecipient = initialFeeRecipient;
        feeBps = initialFeeBps;
        nextStreamId = 1;
    }

    // -------------------------------------------------------------------------
    // Owner configuration (bounded; cannot touch stream funds)
    // -------------------------------------------------------------------------

    /// @notice Update the fee recipient.
    function setFeeRecipient(address newFeeRecipient) external onlyOwner {
        if (newFeeRecipient == address(0)) revert ZeroAddress();
        emit SetFeeRecipient(feeRecipient, newFeeRecipient);
        feeRecipient = newFeeRecipient;
    }

    /// @notice Update the protocol fee. Reverts above MAX_FEE_BPS.
    function setFeeBps(uint256 newFeeBps) external onlyOwner {
        if (newFeeBps > MAX_FEE_BPS) revert FeeTooHigh(newFeeBps, MAX_FEE_BPS);
        emit SetFeeBps(feeBps, newFeeBps);
        feeBps = newFeeBps;
    }

    // -------------------------------------------------------------------------
    // Stream creation
    // -------------------------------------------------------------------------

    /// @notice Create a linear stream with an optional cliff.
    /// @dev The sender must have approved `totalAmount` of `token` to this contract.
    ///      The principal is credited from tokens actually received (fee-on-transfer safe),
    ///      then a bounded protocol fee is skimmed to `feeRecipient`.
    /// @param recipient Beneficiary of the stream.
    /// @param token ERC20 to stream.
    /// @param totalAmount Amount to pull from the sender (pre fee-on-transfer).
    /// @param startTime When releasing begins.
    /// @param cliffTime Time before which nothing is withdrawable; 0 for no cliff.
    /// @param endTime When the principal is fully released.
    /// @param cancelable Whether the stream can be canceled.
    /// @return streamId The id of the newly created stream.
    function createStream(
        address recipient,
        address token,
        uint256 totalAmount,
        uint40 startTime,
        uint40 cliffTime,
        uint40 endTime,
        bool cancelable
    ) external nonReentrant returns (uint256 streamId) {
        if (recipient == address(0) || token == address(0)) revert ZeroAddress();
        if (totalAmount == 0) revert ZeroAmount();
        if (endTime <= startTime) revert InvalidTimeRange(startTime, endTime);
        if (cliffTime != 0 && (cliffTime < startTime || cliffTime > endTime)) {
            revert InvalidCliff(startTime, cliffTime, endTime);
        }

        // Credit the principal from tokens actually received (fee-on-transfer safe).
        IERC20 erc20 = IERC20(token);
        uint256 balanceBefore = erc20.balanceOf(address(this));
        erc20.safeTransferFrom(msg.sender, address(this), totalAmount);
        uint256 received = erc20.balanceOf(address(this)) - balanceBefore;
        if (received == 0) revert NothingReceived();

        // Skim the bounded protocol fee once, at creation.
        uint256 fee = Math.mulDiv(received, feeBps, MAX_BPS);
        uint256 principal = received - fee;
        if (principal == 0) revert NothingReceived();

        streamId = nextStreamId++;
        _streams[streamId] = Stream({
            sender: msg.sender,
            recipient: recipient,
            token: token,
            deposit: principal.toUint128(),
            withdrawn: 0,
            refunded: 0,
            startTime: startTime,
            cliffTime: cliffTime,
            endTime: endTime,
            cancelable: cancelable,
            canceled: false
        });

        emit StreamCreated(
            streamId, msg.sender, recipient, token, principal, fee, startTime, cliffTime, endTime, cancelable
        );

        if (fee != 0) {
            erc20.safeTransfer(feeRecipient, fee);
        }
    }

    // -------------------------------------------------------------------------
    // Withdraw
    // -------------------------------------------------------------------------

    /// @notice Withdraw up to the withdrawable amount to the recipient.
    /// @dev Callable by the recipient or an approved withdrawer.
    function withdraw(uint256 streamId, uint256 amount) external nonReentrant {
        _withdraw(streamId, amount);
    }

    /// @notice Withdraw the full withdrawable amount to the recipient.
    function withdrawMax(uint256 streamId) external nonReentrant returns (uint256 amount) {
        amount = withdrawableAmount(streamId);
        _withdraw(streamId, amount);
    }

    function _withdraw(uint256 streamId, uint256 amount) private {
        Stream storage s = _streams[streamId];
        if (s.sender == address(0)) revert StreamNull(streamId);

        address recipient = s.recipient;
        if (msg.sender != recipient && msg.sender != _approved[streamId]) {
            revert Unauthorized(streamId, msg.sender);
        }
        if (amount == 0) revert ZeroAmount();

        uint256 withdrawable = withdrawableAmount(streamId);
        if (amount > withdrawable) revert Overdraw(streamId, amount, withdrawable);

        // Effects
        s.withdrawn += uint128(amount);

        // Interactions
        emit WithdrawFromStream(streamId, recipient, msg.sender, amount);
        IERC20(s.token).safeTransfer(recipient, amount);
    }

    // -------------------------------------------------------------------------
    // Cancel
    // -------------------------------------------------------------------------

    /// @notice Cancel a cancelable stream. The recipient is paid the streamed-but-unwithdrawn
    ///         amount and the sender is refunded the unstreamed remainder. Both are settled
    ///         immediately; the stream is thereafter Canceled with nothing left owed.
    /// @dev Callable by the sender or the recipient.
    function cancel(uint256 streamId) external nonReentrant {
        Stream storage s = _streams[streamId];
        if (s.sender == address(0)) revert StreamNull(streamId);
        if (msg.sender != s.sender && msg.sender != s.recipient) {
            revert Unauthorized(streamId, msg.sender);
        }
        if (!s.cancelable) revert NotCancelable(streamId);
        if (s.canceled) revert AlreadyCanceled(streamId);

        uint256 streamed = _streamedAmount(s);
        uint256 recipientAmount = streamed - s.withdrawn; // streamed but not yet withdrawn
        uint256 senderRefund = uint256(s.deposit) - streamed; // unstreamed remainder

        // Effects
        s.canceled = true;
        s.withdrawn = uint128(streamed);
        s.refunded = uint128(senderRefund);

        address recipient = s.recipient;
        address sender = s.sender;
        IERC20 token = IERC20(s.token);

        emit CancelStream(streamId, sender, recipient, recipientAmount, senderRefund);

        // Interactions
        if (recipientAmount != 0) token.safeTransfer(recipient, recipientAmount);
        if (senderRefund != 0) token.safeTransfer(sender, senderRefund);
    }

    // -------------------------------------------------------------------------
    // Recipient management
    // -------------------------------------------------------------------------

    /// @notice Transfer stream ownership to a new recipient. Clears any withdraw approval.
    /// @dev Callable by the current recipient only.
    function transferRecipient(uint256 streamId, address newRecipient) external {
        Stream storage s = _streams[streamId];
        if (s.sender == address(0)) revert StreamNull(streamId);
        if (msg.sender != s.recipient) revert Unauthorized(streamId, msg.sender);
        if (newRecipient == address(0)) revert ZeroAddress();

        emit TransferRecipient(streamId, s.recipient, newRecipient);
        s.recipient = newRecipient;
        delete _approved[streamId];
    }

    /// @notice Approve `spender` to withdraw on the recipient's behalf. address(0) clears it.
    /// @dev Callable by the current recipient only.
    function approveWithdrawer(uint256 streamId, address spender) external {
        Stream storage s = _streams[streamId];
        if (s.sender == address(0)) revert StreamNull(streamId);
        if (msg.sender != s.recipient) revert Unauthorized(streamId, msg.sender);

        _approved[streamId] = spender;
        emit ApproveWithdrawer(streamId, spender);
    }

    // -------------------------------------------------------------------------
    // Views
    // -------------------------------------------------------------------------

    /// @notice Total principal released by the stream at the current time.
    /// @dev 0 before start/cliff; linear from start to end; full at/after end.
    ///      Frozen at the cancel point for canceled streams.
    function streamedAmount(uint256 streamId) public view returns (uint256) {
        Stream storage s = _streams[streamId];
        if (s.sender == address(0)) revert StreamNull(streamId);
        return _streamedAmount(s);
    }

    function _streamedAmount(Stream storage s) private view returns (uint256) {
        // Once canceled, the streamed figure is frozen at s.withdrawn (set on cancel).
        if (s.canceled) return s.withdrawn;

        uint256 nowTs = block.timestamp;
        if (nowTs < s.startTime) return 0;
        if (s.cliffTime != 0 && nowTs < s.cliffTime) return 0;
        if (nowTs >= s.endTime) return s.deposit;

        // Linear from start -> end. Cliff only gates the zero period; after the cliff
        // the released amount equals the linear-from-start value (it "catches up").
        uint256 elapsed = nowTs - s.startTime;
        uint256 duration = uint256(s.endTime) - s.startTime;
        return Math.mulDiv(uint256(s.deposit), elapsed, duration);
    }

    /// @notice Amount currently withdrawable by the recipient (streamed minus withdrawn).
    function withdrawableAmount(uint256 streamId) public view returns (uint256) {
        Stream storage s = _streams[streamId];
        if (s.sender == address(0)) revert StreamNull(streamId);
        return _streamedAmount(s) - s.withdrawn;
    }

    /// @notice Principal still held by the contract for this stream (deposit minus
    ///         withdrawn minus refunded). This is the stream's outstanding obligation.
    function remainingBalance(uint256 streamId) public view returns (uint256) {
        Stream storage s = _streams[streamId];
        if (s.sender == address(0)) revert StreamNull(streamId);
        return uint256(s.deposit) - s.withdrawn - s.refunded;
    }

    /// @notice Lifecycle status of a stream.
    function statusOf(uint256 streamId) public view returns (Status) {
        Stream storage s = _streams[streamId];
        if (s.sender == address(0)) revert StreamNull(streamId);
        if (s.canceled) return Status.Canceled;
        if (s.withdrawn == s.deposit) return Status.Depleted;
        if (_streamedAmount(s) == s.deposit) return Status.Settled;
        if (block.timestamp < s.startTime) return Status.Pending;
        return Status.Streaming;
    }

    /// @notice Full stream record.
    function getStream(uint256 streamId) external view returns (Stream memory) {
        Stream storage s = _streams[streamId];
        if (s.sender == address(0)) revert StreamNull(streamId);
        return s;
    }

    /// @notice Address approved to withdraw on the recipient's behalf (0 if none).
    function getApproved(uint256 streamId) external view returns (address) {
        return _approved[streamId];
    }
}
