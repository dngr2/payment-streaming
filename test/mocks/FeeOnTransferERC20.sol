// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @notice ERC20 that burns a fixed basis-points fee on every transfer, so the
///         recipient always receives less than the sent amount. Used to prove the
///         StreamManager credits principal from tokens actually received.
contract FeeOnTransferERC20 is ERC20 {
    uint256 public immutable feeBps; // fee burned per transfer, in basis points
    uint256 public constant BPS = 10_000;

    constructor(string memory name_, string memory symbol_, uint256 feeBps_) ERC20(name_, symbol_) {
        require(feeBps_ < BPS, "fee too high");
        feeBps = feeBps_;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    /// @dev Overrides the v5 hook: burns `fee` from the moved amount in transit.
    function _update(address from, address to, uint256 value) internal override {
        if (from == address(0) || to == address(0) || feeBps == 0) {
            // mint / burn: no transfer fee
            super._update(from, to, value);
            return;
        }
        uint256 fee = (value * feeBps) / BPS;
        if (fee != 0) {
            super._update(from, address(0), fee); // burn the fee
        }
        super._update(from, to, value - fee);
    }
}
