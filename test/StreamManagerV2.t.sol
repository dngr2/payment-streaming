// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {StreamManager} from "../src/StreamManager.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {FeeOnTransferERC20} from "./mocks/FeeOnTransferERC20.sol";

/// @notice Tests for the deep-dive v2 additions: top-up and batch create.
contract StreamManagerV2Test is Test {
    StreamManager internal mgr;
    MockERC20 internal token;

    address internal owner = address(0xA11CE);
    address internal feeRecipient = address(0xFEE);
    address internal sender = address(0x5E11D);
    address internal recipient = address(0xB0B);
    address internal stranger = address(0xDEAD);

    uint40 internal constant T0 = 1_000_000;
    uint40 internal constant START = T0;
    uint40 internal constant END = T0 + 1000;
    uint256 internal constant AMT = 1000e18;

    function setUp() public {
        vm.warp(T0);
        token = new MockERC20("Token", "TKN", 18);
        mgr = new StreamManager(owner, feeRecipient, 0);
        token.mint(sender, 1_000_000e18);
        vm.prank(sender);
        token.approve(address(mgr), type(uint256).max);
    }

    function _create(uint40 cliff, bool cancelable) internal returns (uint256 id) {
        vm.prank(sender);
        id = mgr.createStream(recipient, address(token), AMT, START, cliff, END, cancelable);
    }

    // --------------------------------------------------------------------- //
    // top-up: rate preserved, end extended, no retroactive release
    // --------------------------------------------------------------------- //

    function test_TopUp_ExtendsEndPreservesRate() public {
        uint256 id = _create(0, true);

        vm.warp(uint256(T0) + 500); // streamed = 500e18
        assertEq(mgr.streamedAmount(id), 500e18);

        vm.prank(sender);
        uint40 newEnd = mgr.topUp(id, 1000e18); // double the principal

        // newDeposit = 2000e18; newDuration = 1000 * 2000/1000 = 2000; newEnd = T0 + 2000
        assertEq(newEnd, T0 + 2000);
        StreamManager.Stream memory s = mgr.getStream(id);
        assertEq(s.deposit, 2000e18);
        assertEq(s.endTime, T0 + 2000);
        assertEq(s.startTime, START);

        // streamed figure is unchanged at the instant of top-up (no retroactive release)
        assertEq(mgr.streamedAmount(id), 500e18);

        // rate preserved: 500s later another 500e18 has accrued (1e18/s throughout)
        vm.warp(uint256(T0) + 1000);
        assertEq(mgr.streamedAmount(id), 1000e18);

        // full at the new end
        vm.warp(uint256(T0) + 2000);
        assertEq(mgr.streamedAmount(id), 2000e18);
    }

    function test_TopUp_DoesNotDisturbPriorWithdrawal() public {
        uint256 id = _create(0, true);

        vm.warp(uint256(T0) + 400); // streamed = 400e18
        vm.prank(recipient);
        mgr.withdraw(id, 200e18);
        assertEq(mgr.withdrawableAmount(id), 200e18);

        vm.prank(sender);
        mgr.topUp(id, 1000e18);

        // withdrawable unchanged at the top-up instant; no underflow
        assertEq(mgr.streamedAmount(id), 400e18);
        assertEq(mgr.withdrawableAmount(id), 200e18);
    }

    function test_TopUp_ConservationAcrossLifecycle() public {
        vm.prank(owner);
        mgr.setFeeBps(300); // 3%

        vm.prank(sender);
        uint256 id = mgr.createStream(recipient, address(token), AMT, START, 0, END, true);
        uint256 feeCreate = (AMT * 300) / 10_000; // 30e18

        vm.warp(uint256(T0) + 400);
        vm.prank(recipient);
        mgr.withdraw(id, 100e18);

        // top up mid-flight
        vm.prank(sender);
        mgr.topUp(id, 500e18);
        uint256 feeTop = (500e18 * 300) / 10_000; // 15e18
        uint256 received = AMT + 500e18;
        uint256 feeTotal = feeCreate + feeTop;

        // drain to the end, then cancel (nothing left to refund)
        StreamManager.Stream memory s = mgr.getStream(id);
        vm.warp(uint256(s.endTime));
        vm.prank(recipient);
        mgr.withdrawMax(id);

        vm.prank(sender);
        mgr.cancel(id);

        s = mgr.getStream(id);
        uint256 remaining = uint256(s.deposit) - s.withdrawn - s.refunded;
        // deposited(received) == withdrawn + remaining + refunded + fee
        assertEq(received, uint256(s.withdrawn) + remaining + uint256(s.refunded) + feeTotal);
        assertEq(uint256(s.deposit), received - feeTotal);
        assertEq(token.balanceOf(feeRecipient), feeTotal);
        assertEq(token.balanceOf(address(mgr)), remaining); // 0 after full drain
    }

    function test_TopUp_WithFeeSkimmed() public {
        vm.prank(owner);
        mgr.setFeeBps(250); // 2.5%
        vm.prank(sender);
        uint256 id = mgr.createStream(recipient, address(token), AMT, START, 0, END, true);
        // deposit after create fee: 975e18
        uint256 feeBefore = token.balanceOf(feeRecipient);

        vm.prank(sender);
        mgr.topUp(id, 400e18);
        // topUp fee = 400e18 * 250/10000 = 10e18; added principal = 390e18
        assertEq(token.balanceOf(feeRecipient), feeBefore + 10e18);
        StreamManager.Stream memory s = mgr.getStream(id);
        assertEq(s.deposit, 975e18 + 390e18);
    }

    function test_TopUp_FeeOnTransferCreditsReceived() public {
        FeeOnTransferERC20 fot = new FeeOnTransferERC20("FoT", "FOT", 100); // 1% burn
        fot.mint(sender, 2000e18);
        vm.prank(sender);
        fot.approve(address(mgr), type(uint256).max);

        vm.prank(sender);
        uint256 id = mgr.createStream(recipient, address(fot), 1000e18, START, 0, END, true);
        // create received 990e18 => deposit 990e18

        vm.prank(sender);
        mgr.topUp(id, 1000e18);
        // topUp received 990e18 (1% burned), no protocol fee => deposit 990 + 990 = 1980e18
        StreamManager.Stream memory s = mgr.getStream(id);
        assertEq(s.deposit, 1980e18);
        assertEq(fot.balanceOf(address(mgr)), 1980e18);
    }

    function test_TopUp_OnlySender() public {
        uint256 id = _create(0, true);
        vm.warp(uint256(T0) + 100);

        vm.prank(recipient);
        vm.expectRevert(abi.encodeWithSelector(StreamManager.Unauthorized.selector, id, recipient));
        mgr.topUp(id, 1e18);

        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(StreamManager.Unauthorized.selector, id, stranger));
        mgr.topUp(id, 1e18);
    }

    function test_TopUp_RevertAfterEnd() public {
        uint256 id = _create(0, true);
        vm.warp(uint256(END));
        vm.prank(sender);
        vm.expectRevert(abi.encodeWithSelector(StreamManager.StreamEnded.selector, id));
        mgr.topUp(id, 1e18);
    }

    function test_TopUp_RevertCanceled() public {
        uint256 id = _create(0, true);
        vm.warp(uint256(T0) + 200);
        vm.prank(sender);
        mgr.cancel(id);
        vm.prank(sender);
        vm.expectRevert(abi.encodeWithSelector(StreamManager.AlreadyCanceled.selector, id));
        mgr.topUp(id, 1e18);
    }

    function test_TopUp_RevertZeroAmount() public {
        uint256 id = _create(0, true);
        vm.prank(sender);
        vm.expectRevert(StreamManager.ZeroAmount.selector);
        mgr.topUp(id, 0);
    }

    function test_TopUp_RevertNullStream() public {
        vm.prank(sender);
        vm.expectRevert(abi.encodeWithSelector(StreamManager.StreamNull.selector, 999));
        mgr.topUp(999, 1e18);
    }

    function test_TopUp_NonCancelableAllowed() public {
        uint256 id = _create(0, false); // non-cancelable stream can still be topped up
        vm.warp(uint256(T0) + 300);
        vm.prank(sender);
        uint40 newEnd = mgr.topUp(id, 500e18);
        assertEq(newEnd, T0 + 1500); // 1000 * 1500/1000
        StreamManager.Stream memory s = mgr.getStream(id);
        assertEq(s.deposit, 1500e18);
        assertFalse(s.cancelable);
    }

    // --------------------------------------------------------------------- //
    // batch create
    // --------------------------------------------------------------------- //

    function _params(address to, uint256 amt, bool cancelable)
        internal
        view
        returns (StreamManager.CreateParams memory p)
    {
        p = StreamManager.CreateParams({
            recipient: to,
            token: address(token),
            totalAmount: amt,
            startTime: START,
            cliffTime: 0,
            endTime: END,
            cancelable: cancelable
        });
    }

    function test_BatchCreate_CreatesAll() public {
        StreamManager.CreateParams[] memory ps = new StreamManager.CreateParams[](3);
        ps[0] = _params(recipient, 100e18, true);
        ps[1] = _params(stranger, 200e18, false);
        ps[2] = _params(recipient, 300e18, true);

        uint256 balBefore = token.balanceOf(sender);
        vm.prank(sender);
        uint256[] memory ids = mgr.createStreamBatch(ps);

        assertEq(ids.length, 3);
        assertEq(ids[0], 1);
        assertEq(ids[1], 2);
        assertEq(ids[2], 3);
        assertEq(mgr.getStream(ids[0]).deposit, 100e18);
        assertEq(mgr.getStream(ids[1]).deposit, 200e18);
        assertEq(mgr.getStream(ids[2]).recipient, recipient);
        assertFalse(mgr.getStream(ids[1]).cancelable);

        // sender funded all three; contract holds the total
        assertEq(balBefore - token.balanceOf(sender), 600e18);
        assertEq(token.balanceOf(address(mgr)), 600e18);
        assertEq(mgr.nextStreamId(), 4);
    }

    function test_BatchCreate_WithFeePerStream() public {
        vm.prank(owner);
        mgr.setFeeBps(1000); // 10%

        StreamManager.CreateParams[] memory ps = new StreamManager.CreateParams[](2);
        ps[0] = _params(recipient, 100e18, true);
        ps[1] = _params(recipient, 200e18, true);

        vm.prank(sender);
        uint256[] memory ids = mgr.createStreamBatch(ps);

        // 10% fee each => fees 10e18 + 20e18 = 30e18; principals 90e18 + 180e18
        assertEq(token.balanceOf(feeRecipient), 30e18);
        assertEq(mgr.getStream(ids[0]).deposit, 90e18);
        assertEq(mgr.getStream(ids[1]).deposit, 180e18);
    }

    function test_BatchCreate_EmptyReverts() public {
        StreamManager.CreateParams[] memory ps = new StreamManager.CreateParams[](0);
        vm.prank(sender);
        vm.expectRevert(StreamManager.ZeroAmount.selector);
        mgr.createStreamBatch(ps);
    }

    function test_BatchCreate_OneBadRevertsWholeBatch() public {
        StreamManager.CreateParams[] memory ps = new StreamManager.CreateParams[](2);
        ps[0] = _params(recipient, 100e18, true);
        ps[1] = _params(recipient, 200e18, true);
        ps[1].endTime = START; // invalid range

        vm.prank(sender);
        vm.expectRevert(abi.encodeWithSelector(StreamManager.InvalidTimeRange.selector, START, START));
        mgr.createStreamBatch(ps);

        // atomic: nothing created, no funds moved
        assertEq(mgr.nextStreamId(), 1);
        assertEq(token.balanceOf(address(mgr)), 0);
    }
}
