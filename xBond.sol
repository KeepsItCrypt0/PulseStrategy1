// SPDX-License-Identifier: MIT
pragma solidity 0.8.29;

// OpenZeppelin Imports
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";

/**
 * @title PulseStrategy
 * @notice A Decentralized PLSX Reserve, allows issuance/redemption of xBond.
 * @dev xBond has a 4.5% tax on transfers (2.7% burned, 1.8% to strategy controller, excluding redemptions).
 */
contract PulseStrategy is ERC20, ReentrancyGuard {
    using SafeERC20 for IERC20;

    // --------------------------------------
    // Errors
    // --------------------------------------
    error InvalidAmount();
    error InsufficientBalance();
    error ZeroAddress();
    error IssuancePeriodEnded();
    error InsufficientContractBalance();
    error InsufficientAllowance();

    // --------------------------------------
    // Events
    // --------------------------------------
    event SharesIssued(address indexed buyer, uint256 shares, uint256 totalFee);
    event SharesRedeemed(address indexed redeemer, uint256 shares, uint256 plsx);
    event TransferTaxApplied(address indexed from, address indexed to, uint256 amountAfterTax, uint256 xBondToController, uint256 burned);

    // --------------------------------------
    // State Variables
    // --------------------------------------
    uint256 private _totalSupplyMinted;
    uint48 private _deploymentTime;

    // --------------------------------------
    // Immutable Variables
    // --------------------------------------
    address private immutable _plsx = 0x95B303987A60C71504D99Aa1b13B4DA07b0790ab;
    address private immutable _strategyController;

    // --------------------------------------
    // Constants
    // --------------------------------------
    uint16 private constant _FEE_BASIS_POINTS = 450; // 4.5%
    uint256 private constant _MIN_LIQUIDITY = 1e18; // 1 PLSX
    uint256 private constant _MIN_TRANSFER = 1e18; // 1 xBond
    uint16 private constant _BASIS_DENOMINATOR = 10000; // 10,000
    uint256 private constant _ISSUANCE_PERIOD = 180 days; // ~6 months

    // --------------------------------------
    // Constructor
    // --------------------------------------
    constructor() ERC20("PulseStrategy", "xBond") {
        if (_plsx == address(0)) revert ZeroAddress();
        _strategyController = msg.sender;
        _deploymentTime = uint48(block.timestamp);
    }

    // --------------------------------------
    // Internal Helpers
    // --------------------------------------
    function _calculateFee(uint256 amount) private pure returns (uint256) {
        return (amount * _FEE_BASIS_POINTS) / _BASIS_DENOMINATOR;
    }

    // --------------------------------------
    // Transfer and Tax Logic
    // --------------------------------------
    function _update(address from, address to, uint256 value) internal override nonReentrant {
        if (value < _MIN_TRANSFER && from != address(0) && to != address(0)) revert InvalidAmount();
        if (from != address(0) && balanceOf(from) < value) revert InsufficientBalance();

        if (from == _strategyController || to == _strategyController || from == address(this) || to == address(this)) {
            super._update(from, to, value);
            emit TransferTaxApplied(from, to, value, 0, 0);
            return;
        }

        uint256 fee = _calculateFee(value);
        uint256 burnShare = (fee * 60) / 100;
        uint256 controllerShare = fee - burnShare;
        uint256 amountAfterTax = value - fee;

        if (burnShare > 0) _burn(from, burnShare);
        if (controllerShare > 0) super._update(from, _strategyController, controllerShare);
        super._update(from, to, amountAfterTax);

        emit TransferTaxApplied(from, to, amountAfterTax, controllerShare, burnShare);
    }

    // --------------------------------------
    // Share Issuance and Redemption
    // --------------------------------------
    function issueShares(uint256 plsxAmount) external nonReentrant {
        if (plsxAmount < _MIN_LIQUIDITY || block.timestamp > _deploymentTime + _ISSUANCE_PERIOD)
            revert IssuancePeriodEnded();
        if (IERC20(_plsx).allowance(msg.sender, address(this)) < plsxAmount) revert InsufficientAllowance();

        IERC20(_plsx).safeTransferFrom(msg.sender, address(this), plsxAmount);
        uint256 fee = _calculateFee(plsxAmount);

        uint256 shares = plsxAmount - fee;
        uint256 feeToController = fee / 2;
        uint256 sharesToController = feeToController;

        if (feeToController > 0) IERC20(_plsx).safeTransfer(_strategyController, feeToController);
        _mint(msg.sender, shares);
        _totalSupplyMinted = _totalSupplyMinted + shares;
        if (sharesToController > 0) {
            _mint(_strategyController, sharesToController);
            _totalSupplyMinted = _totalSupplyMinted + sharesToController;
        }
        emit SharesIssued(msg.sender, shares, fee);
    }

    function redeemShares(uint256 shareAmount) external nonReentrant {
        if (shareAmount == 0 || balanceOf(msg.sender) < shareAmount) revert InvalidAmount();
        uint256 plsxAmount = (IERC20(_plsx).balanceOf(address(this)) * shareAmount) / totalSupply();
        if (plsxAmount == 0) revert InsufficientContractBalance();

        _burn(msg.sender, shareAmount);
        IERC20(_plsx).safeTransfer(msg.sender, plsxAmount);
        emit SharesRedeemed(msg.sender, shareAmount, plsxAmount);
    }

    // --------------------------------------
    // View Functions
    // --------------------------------------
    function getContractMetrics() external view returns (
        uint256 contractTotalSupply,
        uint256 plsxBalance,
        uint256 totalMinted,
        uint256 totalBurned,
        uint256 plsxBackingRatio
    ) {
        contractTotalSupply = totalSupply();
        plsxBalance = IERC20(_plsx).balanceOf(address(this));
        totalMinted = _totalSupplyMinted;
        totalBurned = totalMinted - contractTotalSupply;
        plsxBackingRatio = contractTotalSupply == 0 ? 0 : (plsxBalance * 1e18) / contractTotalSupply;
    }

    function getIssuanceStatus() external view returns (bool isActive, uint256 timeRemaining) {
        isActive = block.timestamp <= _deploymentTime + _ISSUANCE_PERIOD;
        timeRemaining = isActive ? _deploymentTime + _ISSUANCE_PERIOD - block.timestamp : 0;
    }
}