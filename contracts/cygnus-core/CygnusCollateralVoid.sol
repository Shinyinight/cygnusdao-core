// SPDX-License-Identifier: Unlicensed
pragma solidity >=0.8.4;

// Dependencies
import { ICygnusCollateralVoid } from "./interfaces/ICygnusCollateralVoid.sol";
import { CygnusCollateralControl } from "./CygnusCollateralControl.sol";

// Libraries
import { Address } from "./libraries/Address.sol";
import { ChefHelper } from "./libraries/ChefHelper.sol";
import { PRBMathUD60x18 } from "./libraries/PRBMathUD60x18.sol";
import { SafeErc20 } from "./libraries/SafeErc20.sol";

// Interfaces
import { CygnusTerminal } from "./CygnusTerminal.sol";
import { ICygnusFactory } from "./interfaces/ICygnusFactory.sol";
import { IDexPair } from "./interfaces/IDexPair.sol";
import { IDexRouter02 } from "./interfaces/IDexRouter.sol";
import { IErc20 } from "./interfaces/IErc20.sol";
import { IRewarder, IMiniChef } from "./interfaces/IMiniChef.sol";

/**
 *  @title  CygnusCollateralChef Assigns the masterchef/rewards contract (if any) to harvest and reinvest rewards
 *  @notice This contract is considered optional and default state is offline (bool `voidActivated`)
 *          It is the only contract in Cygnus that should be changed according to the LP Token the collateral
 *          consists of. Most functions are kept as private as they are only relevant to this contract and the
 *          rest of the contracts are indifferent to this
 */
contract CygnusCollateralVoid is ICygnusCollateralVoid, CygnusCollateralControl {
    /*  ═══════════════════════════════════════════════════════════════════════════════════════════════════════ 
            1. LIBRARIES
        ═══════════════════════════════════════════════════════════════════════════════════════════════════════  */

    /**
     *  @custom:library PRBMathUD60x18 For uint256 fixed point math, also imports the main library `PRBMath`.
     */
    using PRBMathUD60x18 for uint256;

    /**
     *  @custom:library SafeErc20 Low level handling of Erc20 tokens
     */
    using SafeErc20 for IErc20;

    /**
     *  @custom:library ChefHelper Helper functions for interacting with dexes and handling rewards
     */
    using ChefHelper for address;

    /**
     *  @custom:library Address Verify if msgSender is contract or EOA
     */
    using Address for address;

    /*  ═══════════════════════════════════════════════════════════════════════════════════════════════════════ 
            2. STORAGE
        ═══════════════════════════════════════════════════════════════════════════════════════════════════════  */

    /*  ────────────────────────────────────────────── Private ───────────────────────────────────────────────  */

    //  Keep private as these are picked up by LP Token and Cygnus factory in construct

    /**
     *  @notice Address of the chain's native token (WETH/nativeToken/WMATIC/etc.)
     */
    address private immutable nativeToken;

    /**
     *  @notice The first token from the underlying LP Token
     */
    address private immutable token0;

    /**
     *  @notice The second token from the underlying LP Token
     */
    address private immutable token1;

    /*  ─────────────────────────────────────────────── Public ───────────────────────────────────────────────  */

    /**
     *  @inheritdoc ICygnusCollateralVoid
     */
    IDexRouter02 public override dexRouter;

    /**
     *  @inheritdoc ICygnusCollateralVoid
     */
    address public override rewardsToken;

    /**
     *  @inheritdoc ICygnusCollateralVoid
     */
    uint256 public override swapFeeFactor;

    /**
     *  @inheritdoc ICygnusCollateralVoid
     */
    uint256 public constant override REINVEST_REWARD = 0.01e18;

    /*  ═══════════════════════════════════════════════════════════════════════════════════════════════════════ 
            3. CONSTRUCTOR
        ═══════════════════════════════════════════════════════════════════════════════════════════════════════  */

    /**
     *  @notice Constructs the Cygnus Void contract which handles rewards reinvestments
     *  @dev Assign token0 and token1 in constructor as the underlying is always a univ2 LP Token
     *  @dev Assign nativeToken from the factory
     */
    constructor() {
        // Token0
        token0 = IDexPair(underlying).token0();

        // Token1
        token1 = IDexPair(underlying).token1();

        // Factory
        nativeToken = ICygnusFactory(hangar18).nativeToken();
    }

    /*  ═══════════════════════════════════════════════════════════════════════════════════════════════════════ 
            4. MODIFIERS
        ═══════════════════════════════════════════════════════════════════════════════════════════════════════  */

    /**
     *  @custom:modifier chargeVoid Reinvests rewards from masterchef/rewarder before depositing
     */
    modifier chargeVoid() {
        reinvest();
        _;
    }

    /**
     *  @custom:modifier onlyEOA Modifier which reverts transaction if msg.sender is considered a contract
     */
    modifier onlyEOA() {
        checkEOA();
        _;
    }

    /*  ═══════════════════════════════════════════════════════════════════════════════════════════════════════ 
            5. CONSTANT FUNCTIONS
        ═══════════════════════════════════════════════════════════════════════════════════════════════════════  */

    /*  ────────────────────────────────────────────── Private ────────────────────────────────────────────────  */

    /**
     *  @notice Checks the `token` balance of this contract
     *  @param token The token to view balance of
     *  @return This contract's balance
     */
    function contractBalanceOf(address token) private view returns (uint256) {
        return IErc20(token).balanceOf(address(this));
    }

    /**
     *  @notice Reverts if it is not considered a EOA
     */
    function checkEOA() private view {
        if ((_msgSender()).isContract()) {
            revert CygnusCollateralChef__OnlyAccountsAllowed(_msgSender());
        }
    }

    /*  ────────────────────────────────────────────── External ───────────────────────────────────────────────  */

    /**
     *  @inheritdoc ICygnusCollateralVoid
     */
    function getMasterChef() external view override returns (address) {
        return address(rewarder);
    }

    /**
     *  @inheritdoc ICygnusCollateralVoid
     */
    function getPoolId() external view override returns (uint256) {
        return pid;
    }

    /*  ═══════════════════════════════════════════════════════════════════════════════════════════════════════ 
            6. NON-CONSTANT FUNCTIONS
        ═══════════════════════════════════════════════════════════════════════════════════════════════════════  */

    /*  ────────────────────────────────────────────── Private ────────────────────────────────────────────────  */

    /**
     *  @notice Grants allowance to the dex' router to handle our rewards
     *  @param token The address of the token we are approving
     *  @param amount The amount to approve
     */
    function approveDexRouter(address token, uint256 amount) private {
        if (IErc20(token).allowance(address(this), address(dexRouter)) >= amount) {
            return;
        } else {
            token.safeApprove(address(dexRouter), type(uint256).max);
        }
    }

    /**
     *  @notice Swap tokens function used by Reinvest
     *  @param tokenIn address of the token we are swapping
     *  @param tokenOut Address of the token we are receiving
     *  @param amount Amount of TokenIn we are swapping
     */
    function swapExactTokensForTokens(
        address tokenIn,
        address tokenOut,
        uint256 amount
    ) private {
        address[] memory path = new address[](2);

        path[0] = address(tokenIn);

        path[1] = address(tokenOut);

        // Safe Approve router
        approveDexRouter(tokenIn, amount);

        // Swap tokens
        dexRouter.swapExactTokensForTokens(amount, 0, path, address(this), type(uint256).max);
    }

    /**
     *  @notice Function to add liquidity to DEX
     *  @param tokenA The address of the LP Token's token0
     *  @param tokenB The address of the LP Token's token1
     *  @param amountA The amount of token A to add as liquidity
     *  @param amountB The amount of token B to add as liquidity
     *  @return liquidity The total liquidity amount added
     */
    function addLiquidity(
        address tokenA,
        address tokenB,
        uint256 amountA,
        uint256 amountB
    ) private returns (uint256 liquidity) {
        // Approve token A
        approveDexRouter(tokenA, amountA);

        // Approve token B
        approveDexRouter(tokenB, amountB);

        (
            ,
            ,
            /* amountA */
            /* amountB */
            liquidity
        ) = dexRouter.addLiquidity(tokenA, tokenB, amountA, amountB, 0, 0, address(this), type(uint256).max);
    }

    /**
     *  @notice Gets the rewards from the masterchef's rewarder contract for multiple tokens and converts to rewardToken
     */
    function getRewardsPrivate() private returns (uint256) {
        IMiniChef(rewarder).deposit(pid, 0);
        return contractBalanceOf(rewardsToken);
    }

    /**
     *  @notice Reinvests rewards token to buy more LP tokens and adds it back to position
     *  @notice As a result the debt owned by borrowers diminishes on every reinvestment as their CygLP tokens
     *          are now worth more. This decrease can be seen in the UI under `Debt Ratio` in the dashboard
     *  @custom:security non-reentrant
     */
    function reinvest() private nonReentrant update {
        // Ignore and return if not activated
        if (!voidActivated) {
            return;
        }

        // 1. Withdraw all the rewards
        uint256 currentRewards = getRewardsPrivate();

        // Return if we haven't accumulated rewards from rewarder contract
        if (currentRewards == 0) {
            return;
        }

        address _nativeToken = nativeToken;

        // 2. Convert all the remaining rewards to token0 or token1
        address tokenA;

        address tokenB;

        if (token0 == rewardsToken || token1 == rewardsToken) {
            (tokenA, tokenB) = token0 == rewardsToken ? (token0, token1) : (token1, token0);
        } else {
            swapExactTokensForTokens(rewardsToken, _nativeToken, currentRewards);

            if (token0 == _nativeToken || token1 == _nativeToken) {
                (tokenA, tokenB) = token0 == _nativeToken ? (token0, token1) : (token1, token0);
            } else {
                swapExactTokensForTokens(_nativeToken, token0, contractBalanceOf(_nativeToken));

                (tokenA, tokenB) = (token0, token1);
            }
        }

        // 3. Convert tokenA to LP Token underlyings
        uint256 totalAmountA = contractBalanceOf(tokenA);

        assert(totalAmountA > 0);

        // prettier-ignore
        (uint256 reserves1, uint256 reserves2, /* BlockTimestamp */) = IDexPair(underlying).getReserves();

        // Assign reservesA
        uint256 reservesA = tokenA == token0 ? reserves1 : reserves2;

        // Get optimal swap amount for token A
        uint256 swapAmount = ChefHelper.optimalDepositA(totalAmountA, reservesA, swapFeeFactor);

        // Swap
        swapExactTokensForTokens(tokenA, tokenB, swapAmount);

        // Add liquidity
        uint256 liquidity = addLiquidity(tokenA, tokenB, totalAmountA - swapAmount, contractBalanceOf(tokenB));

        // 4. Stake the LP Tokens
        rewarder.deposit(pid, liquidity);

        /// @custom:event ReinvestRewards
        emit RechargeVoid(address(this), _msgSender(), currentRewards, liquidity);
    }

    /*  ────────────────────────────────────────────── Internal ───────────────────────────────────────────────  */

    /**
     *  @notice Syncs total rewards balance and total balance of this contract
     *  @dev Overrides CygnusTerminal
     */
    function updateInternal() internal override(CygnusTerminal) {
        // For LP Tokens which don't have void activated
        if (!voidActivated) {
            super.updateInternal();
        }
        // If activated get totalBalance from masterchef
        else {
            (uint256 _totalBalance, ) = rewarder.userInfo(pid, address(this));

            // Update Total Rewards Balance
            totalBalance = _totalBalance;

            /// @custom:event Sync
            emit Sync(totalBalance);
        }
    }

    /*  ────────────────────────────────────────────── External ───────────────────────────────────────────────  */

    /**
     *  @inheritdoc ICygnusCollateralVoid
     *  @custom:security non-reentrant
     */
    function initializeVoid(
        IDexRouter02 dexRouterVoid,
        IMiniChef rewarderVoid,
        address rewardsTokenVoid,
        uint256 pidVoid,
        uint256 swapFeeFactorVoid
    ) external override nonReentrant cygnusAdmin {
        /// @custom:error InvalidRewardsToken Avoid setting twice
        if (rewardsToken != address(0)) {
            revert CygnusCollateralChef__VoidAlreadyInitialized(rewardsTokenVoid);
        }

        // Initialize Router
        dexRouter = dexRouterVoid;

        // Initialize Masterchef for this pool
        rewarder = rewarderVoid;

        // Assign pool ID
        pid = pidVoid;

        // Assign the reward token
        rewardsToken = rewardsTokenVoid;

        // Swap fee for this dex
        swapFeeFactor = swapFeeFactorVoid;

        // Approve dex router in rewards token
        rewardsTokenVoid.safeApprove(address(dexRouterVoid), type(uint256).max);

        // Approve dex router in wavax
        nativeToken.safeApprove(address(dexRouterVoid), type(uint256).max);

        // Approve masterchef/rewarder in underlying
        underlying.safeApprove(address(rewarderVoid), type(uint256).max);

        // Activate
        voidActivated = true;

        /// @custom:event ChargeVoid
        emit ChargeVoid(dexRouterVoid, rewarderVoid, rewardsTokenVoid, pidVoid, swapFeeFactorVoid);
    }

    /**
     *  @inheritdoc ICygnusCollateralVoid
     */
    function reinvestRewards() external override onlyEOA {
        reinvest();
    }
}