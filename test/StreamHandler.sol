// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {CommonBase} from "forge-std/Base.sol";
import {StdCheats} from "forge-std/StdCheats.sol";
import {StdUtils} from "forge-std/StdUtils.sol";
import {StreamManager} from "../src/StreamManager.sol";
import {MockERC20} from "./mocks/MockERC20.sol";

/// @notice Bounded handler driving create/withdraw/cancel/warp across many streams.
///         Records ghost totals so the invariant test can prove funds conservation.
contract StreamHandler is CommonBase, StdCheats, StdUtils {
    StreamManager public immutable mgr;
    MockERC20 public immutable token;

    uint40 internal constant T0 = 1_000_000;

    address[] internal actors;
    uint256[] public streamIds;

    // ghosts, keyed by stream id
    mapping(uint256 => uint256) public gReceived; // tokens actually received at creation
    mapping(uint256 => uint256) public gFee; // protocol fee taken at creation

    uint256 public gTotalReceived;
    uint256 public gTotalFees;

    constructor(StreamManager _mgr, MockERC20 _token) {
        mgr = _mgr;
        token = _token;
        actors.push(address(0x1001));
        actors.push(address(0x1002));
        actors.push(address(0x1003));
        vm.warp(T0);
    }

    function _actor(uint256 seed) internal view returns (address) {
        return actors[seed % actors.length];
    }

    function streamCount() external view returns (uint256) {
        return streamIds.length;
    }

    // --------------------------------------------------------------------- //
    // actions
    // --------------------------------------------------------------------- //

    function createStream(uint256 amtSeed, uint256 startSeed, uint256 durSeed, uint256 cliffSeed, uint256 actorSeed)
        external
    {
        address sender = _actor(actorSeed);
        address recipient = _actor(actorSeed + 1);

        uint256 amount = bound(amtSeed, 1e6, 1_000_000e18);
        uint40 start = uint40(bound(startSeed, block.timestamp, block.timestamp + 5 days));
        uint40 duration = uint40(bound(durSeed, 1, 365 days));
        uint40 end = start + duration;
        // cliff: 0 (none) half the time, else inside [start, end]
        uint40 cliff = cliffSeed % 2 == 0 ? uint40(0) : uint40(bound(cliffSeed, start, end));

        token.mint(sender, amount);
        vm.startPrank(sender);
        token.approve(address(mgr), amount);
        uint256 id = mgr.createStream(recipient, address(token), amount, start, cliff, end, true);
        vm.stopPrank();

        streamIds.push(id);
        uint256 fee = (amount * mgr.feeBps()) / mgr.MAX_BPS();
        gReceived[id] = amount; // MockERC20 has no transfer fee => received == amount
        gFee[id] = fee;
        gTotalReceived += amount;
        gTotalFees += fee;
    }

    function withdraw(uint256 idSeed, uint256 amtSeed) external {
        if (streamIds.length == 0) return;
        uint256 id = streamIds[idSeed % streamIds.length];
        uint256 withdrawable = mgr.withdrawableAmount(id);
        if (withdrawable == 0) return;
        uint256 amount = bound(amtSeed, 1, withdrawable);

        StreamManager.Stream memory s = mgr.getStream(id);
        vm.prank(s.recipient);
        mgr.withdraw(id, amount);
    }

    function cancel(uint256 idSeed) external {
        if (streamIds.length == 0) return;
        uint256 id = streamIds[idSeed % streamIds.length];
        StreamManager.Stream memory s = mgr.getStream(id);
        if (s.canceled) return;
        vm.prank(s.sender);
        mgr.cancel(id);
    }

    function topUp(uint256 idSeed, uint256 amtSeed) external {
        if (streamIds.length == 0) return;
        uint256 id = streamIds[idSeed % streamIds.length];
        StreamManager.Stream memory s = mgr.getStream(id);
        if (s.canceled) return;
        if (block.timestamp >= s.endTime) return;

        uint256 amount = bound(amtSeed, 1e6, 1_000_000e18);
        token.mint(s.sender, amount);
        vm.startPrank(s.sender);
        token.approve(address(mgr), amount);
        mgr.topUp(id, amount);
        vm.stopPrank();

        uint256 fee = (amount * mgr.feeBps()) / mgr.MAX_BPS();
        gReceived[id] += amount; // MockERC20 has no transfer fee => received == amount
        gFee[id] += fee;
        gTotalReceived += amount;
        gTotalFees += fee;
    }

    function warp(uint256 secondsSeed) external {
        uint256 step = bound(secondsSeed, 1 hours, 30 days);
        vm.warp(block.timestamp + step);
    }
}
