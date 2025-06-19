// SPDX-License-Identifier: MIT
pragma solidity 0.8.29;

// OpenZeppelin Imports
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";

/**
 * @title PulseStrategy
 * @notice A decentralized vPLS (Vouch-staked PLS) reserve, allowing xBond and iBond holders to claim PLSTR, redeemable for vPLS.
 * @dev PLSTR has a 0.5% burn fee on transfers (excluding minting and redemptions). Claims use a reward-per-token model weighted by the PLSX/INC supply ratio, updatable every 24 hours.
 */
contract PulseStrategy is ERC20, ReentrancyGuard {
    using SafeERC20 for IERC20;

    // --------------------------------------
    // Errors
    // --------------------------------------
    error InvalidAmount();
    error InsufficientBalance();
    error ZeroAddress();
    error InsufficientContractBalance();
    error NoEligibleTokens();
    error WeightUpdateTooSoon();
    error ZeroTokenSupply();
    error InsufficientAllowance();

    // --------------------------------------
    // Events
    // --------------------------------------
    event TokensDeposited(address indexed depositor, uint256 vPlsAmount);
    event PLSTRClaimed(address indexed claimer, uint256 plstrAmount);
    event PLSTRRedeemed(address indexed redeemer, uint256 plstrAmount, uint256 vPlsAmount);
    event WeightUpdated(uint256 newWeight);
    event PLSTRBurned(address indexed from, uint256 amount);

    // --------------------------------------
    // State Variables
    // --------------------------------------
    uint256 private totalPlstrMinted;
    uint256 private _iBondWeight;
    uint256 private _lastWeightUpdate;
    uint256 private _rewardPerTokenStored;
    mapping(address => uint256) private _userRewardPerTokenPaid;
    mapping(address => uint256) private _userRewards;

    // --------------------------------------
    // Immutable Variables
    // --------------------------------------
    address private immutable _vPls = 0x79BB3A0Ee435f957ce4f54eE8c3CFADc7278da0C;
    address private immutable _xBond = 0x887C5ABAAAC2161E9A742f600B16d5b00850b63b;
    address private immutable _iBond = 0xeD21E067dDBCd189AcB7c43302fB0Dc3b7bF59E0;
    address private immutable _inc = 0x2fa878Ab3F87CC1C9737Fc071108F904c0B0C95d;
    address private immutable _plsx = 0x95B303987A60C71504D99Aa1b13B4DA07b0790ab;

    // --------------------------------------
    // Constants
    // --------------------------------------
    uint256 private constant _MIN_DEPOSIT = 1e18; // 1 vPLS
    uint256 private constant _MIN_TRANSFER = 1e18; // 1 PLSTR
    uint256 private constant _CLAIM_PRECISION = 1e18;
    uint256 private constant _WEIGHT_COOLDOWN = 86400; // 24 hours
    uint256 private constant _INITIAL_IBOND_WEIGHT = 2560115; // PLSX/INC
    uint256 private constant _BURN_FEE = 50; // 0.5% = 50 basis points
    uint256 private constant _FEE_DENOMINATOR = 10000; // 100% = 10000

    // --------------------------------------
    // Constructor
    // --------------------------------------
    constructor() ERC20("PulseStrategy", "PLSTR") {
        if (_xBond == address(0) || _iBond == address(0) || _vPls == address(0) || _inc == address(0) || _plsx == address(0)) revert ZeroAddress();
        _iBondWeight = _INITIAL_IBOND_WEIGHT;
        _lastWeightUpdate = block.timestamp;
    }

    // --------------------------------------
    // Internal Helpers
    // --------------------------------------
    function _getWeightedBalance(address account) private view returns (uint256) {
        return IERC20(_xBond).balanceOf(account) + (IERC20(_iBond).balanceOf(account) * _iBondWeight / _CLAIM_PRECISION);
    }

    
    function _getTotalEligibleSupply() private view returns (uint256) {
        return IERC20(_xBond).totalSupply() + (IERC20(_iBond).totalSupply() * _iBondWeight / _CLAIM_PRECISION);
    }

    
    function _updateReward(address account) private {
        _userRewards[account] = _earned(account);
        _userRewardPerTokenPaid[account] = _rewardPerTokenStored;
    }

    
    function _earned(address account) private view returns (uint256) {
        uint256 weightedBalance = _getWeightedBalance(account);
        return _userRewards[account] + (
            weightedBalance * (_rewardPerTokenStored - _userRewardPerTokenPaid[account]) / _CLAIM_PRECISION
        );
    }

    // --------------------------------------
    // Weight Update Functionality
    // --------------------------------------
    function updateWeight() external {
        if (block.timestamp < _lastWeightUpdate + _WEIGHT_COOLDOWN) revert WeightUpdateTooSoon();

        uint256 incSupply = IERC20(_inc).totalSupply();
        uint256 plsxSupply = IERC20(_plsx).totalSupply();
        if (incSupply == 0 || plsxSupply == 0) revert ZeroTokenSupply();

        uint256 newWeight = (plsxSupply * _CLAIM_PRECISION) / incSupply;
        if (newWeight == 0) revert InvalidAmount();

        _iBondWeight = newWeight;
        _lastWeightUpdate = block.timestamp;

        emit WeightUpdated(newWeight);
    }

    // --------------------------------------
    // Deposit Functionality
    // --------------------------------------
    function depositTokens(uint256 vPlsAmount) external nonReentrant {
        if (vPlsAmount < _MIN_DEPOSIT) revert InvalidAmount();
        if (IERC20(_vPls).allowance(msg.sender, address(this)) < vPlsAmount) revert InsufficientAllowance();

        uint256 totalEligibleSupply = _getTotalEligibleSupply();
        if (totalEligibleSupply > 0) {
            _rewardPerTokenStored += (vPlsAmount * _CLAIM_PRECISION) / totalEligibleSupply;
        }

        IERC20(_vPls).safeTransferFrom(msg.sender, address(this), vPlsAmount);

        emit TokensDeposited(msg.sender, vPlsAmount);
    }

    // --------------------------------------
    // Claim Functionality
    // --------------------------------------
    function claimPLSTR() external nonReentrant {
        _updateReward(msg.sender);
        uint256 reward = _userRewards[msg.sender];
        if (reward == 0) revert NoEligibleTokens();

        _userRewards[msg.sender] = 0;
        _mint(msg.sender, reward);
        totalPlstrMinted += reward;

        emit PLSTRClaimed(msg.sender, reward);
    }

    // --------------------------------------
    // Redemption Functionality
    // --------------------------------------
    function redeemPLSTR(uint256 plstrAmount) external nonReentrant {
        if (plstrAmount == 0 || balanceOf(msg.sender) < plstrAmount) revert InvalidAmount();
        uint256 contractTotalSupply = totalSupply();
        if (contractTotalSupply == 0) revert InsufficientContractBalance();

        uint256 vPlsBalance = IERC20(_vPls).balanceOf(address(this));
        if (vPlsBalance == 0) revert InsufficientContractBalance();

        uint256 vPlsAmount = (vPlsBalance * plstrAmount) / contractTotalSupply;
        if (vPlsAmount == 0) revert InvalidAmount();

        _burn(msg.sender, plstrAmount);
        IERC20(_vPls).safeTransfer(msg.sender, vPlsAmount);

        emit PLSTRRedeemed(msg.sender, plstrAmount, vPlsAmount);
    }

    // --------------------------------------
    // Transfer Functionality with Burn
    // --------------------------------------
    function _update(address from, address to, uint256 amount) internal virtual override {
        if (amount < _MIN_TRANSFER) revert InvalidAmount();
        if (from == address(0) || to == address(0)) {
            super._update(from, to, amount);
            return;
        }
        if (from == address(this) || to == address(this)) {
            super._update(from, to, amount);
            return;
        }

        uint256 burnAmount = (amount * _BURN_FEE) / _FEE_DENOMINATOR;
        uint256 transferAmount = amount - burnAmount;

        if (burnAmount > 0) {
            super._update(from, address(0), burnAmount);
            emit PLSTRBurned(from, burnAmount);
        }

        super._update(from, to, transferAmount);
    }

    // --------------------------------------
    // View Functions
    // --------------------------------------
    function getContractMetrics() external view returns (
        uint256 contractTotalSupply,
        uint256 vPlsBalance,
        uint256 plstrMinted,
        uint256 totalBurned,
        uint256 rewardPerToken,
        uint256 avgPlstrPerBond,
        uint256 backingRatio
    ) {
        contractTotalSupply = totalSupply();
        vPlsBalance = IERC20(_vPls).balanceOf(address(this));
        plstrMinted = totalPlstrMinted;
        totalBurned = totalPlstrMinted - contractTotalSupply;
        rewardPerToken = _rewardPerTokenStored;

        uint256 totalEligibleSupply = _getTotalEligibleSupply();
        avgPlstrPerBond = totalEligibleSupply == 0 ? 0 : (_rewardPerTokenStored * totalEligibleSupply) / _CLAIM_PRECISION;
        backingRatio = contractTotalSupply == 0 ? 0 : (vPlsBalance * _CLAIM_PRECISION) / contractTotalSupply;
    }

    
    function getClaimEligibility(address user) external view returns (
        uint256 claimablePLSTR,
        uint256 xBondBalance,
        uint256 iBondBalance
    ) {
        xBondBalance = IERC20(_xBond).balanceOf(user);
        iBondBalance = IERC20(_iBond).balanceOf(user);
        claimablePLSTR = _earned(user);
    }

    
    function getCurrentWeight() external view returns (uint256) {
        return _iBondWeight;
    }

    
    function getLastWeightUpdate() external view returns (uint256) {
        return _lastWeightUpdate;
    }
}