// SPDX-License-Identifier: MIT
pragma solidity =0.8.4;
pragma experimental ABIEncoderV2;

import {SafeMath} from "@openzeppelin/contracts/utils/math/SafeMath.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {VaultLifecycle} from "../V2/libraries/VaultLifecycle.sol";
import {Vault} from "../V2/libraries/Vault.sol";
import {ShareMath} from "../V2/libraries/ShareMath.sol";
import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";

import {IRibbonVault} from "../V2/interfaces/IRibbonVault.sol";
import {RibbonVaultBase} from "../V2/base/RibbonVaultBase.sol";
import { RibbonVault } from "../V2/base/RibbonVault.sol";

import {GnosisAuction} from "../V2/libraries/GnosisAuction.sol";
import { IRibbonThetaVault } from "../V2/interfaces/IRibbonThetaVault.sol";
import {
    RibbonLongStrangleVaultStorage
} from "../V2/storage/RibbonLongStrangleVaultStorage.sol";

contract RibbonLongStraddleVault is RibbonVault, RibbonLongStrangleVaultStorage {
    using SafeERC20 for IERC20;
    using SafeMath for uint256;
    using ShareMath for Vault.DepositReceipt;

    /************************************************
     *  IMMUTABLES & CONSTANTS
     ***********************************************/

    IRibbonThetaVault public counterpartyPutThetaVault;
    IRibbonThetaVault public counterpartyCallThetaVault;

    /************************************************
     *  CONSTRUCTOR & INITIALIZATION
     ***********************************************/

    /**
     * @notice Initializes the contract with immutable variables
     * @param _weth is the Wrapped Ether contract
     * @param _usdc is the USDC contract
     */
    constructor(
        address _weth, 
        address _usdc,
        address _gammaController,
        address _marginPool,
        address _gnosisEasyAuction
    ) RibbonVault(
        _weth,
        _usdc,
        _gammaController,
        _marginPool,
        _gnosisEasyAuction
        ) {
        require(_usdc != address(0), "!_usdc");
    }

    /**
     * @notice Initializes the OptionVault contract with storage variables.
     * @param _owner is the owner of the vault with critical permissions
     * @param _feeRecipient is the address to recieve vault performance and management fees
     * @param _managementFee is the management fee pct.
     * @param _performanceFee is the perfomance fee pct.
     * @param _tokenName is the name of the token
     * @param _tokenSymbol is the symbol of the token
     * @param _counterpartyPutThetaVault is the address of the put selling vault
     * @param _counterpartyCallThetaVault is the address of the call selling vault
     * @param _vaultParams is the struct with vault general data
     */
    function initialize(
        address _owner,
        address _keeper,
        address _feeRecipient,
        uint256 _managementFee,
        uint256 _performanceFee,
        string memory _tokenName,
        string memory _tokenSymbol,
        address _counterpartyPutThetaVault,
        address _counterpartyCallThetaVault,
        uint256 _optionAllocation,
        Vault.VaultParams calldata _vaultParams
    ) external initializer {
        baseInitialize(
            _owner,
            _keeper,
            _feeRecipient,
            _managementFee,
            _performanceFee,
            _tokenName,
            _tokenSymbol,
            _vaultParams
        );
        require(
            _counterpartyPutThetaVault != address(0),
            "!_counterpartyThetaVault"
        );
        require(
            _counterpartyCallThetaVault != address(0),
            "!_counterpartyThetaVault"
        );
        require(
            IRibbonThetaVault(_counterpartyPutThetaVault).vaultParams().asset ==
                vaultParams.asset,
            "!_counterpartyThetaVault: asset    "
        );
        require(
            IRibbonThetaVault(_counterpartyCallThetaVault).vaultParams().asset ==
                vaultParams.asset,
            "!_counterpartyThetaVault: asset"
        );
        // 1000 = 10%. Needs to be less than 10% of the funds allocated to option.
        require(
            _optionAllocation > 0 &&
                _optionAllocation < 10 * Vault.OPTION_ALLOCATION_MULTIPLIER,
            "!_optionAllocation"
        );
        counterpartyPutThetaVault = IRibbonThetaVault(_counterpartyPutThetaVault);
        counterpartyCallThetaVault = IRibbonThetaVault(_counterpartyCallThetaVault);
        optionAllocation = _optionAllocation;
    }

    /**
     * @notice Updates the price per share of the current round. The current round
     * pps will change right after call rollToNextOption as the gnosis auction contract
     * takes custody of a % of `asset` tokens, and right after we claim the tokens from
     * the action as we may recieve some of `asset` tokens back alongside the oToken,
     * depending on the gnosis auction outcome. Finally it will change at the end of the week
     * if the oTokens are ITM
     */
    function updatePPS(bool isWithdraw) internal {
        uint256 currentRound = vaultState.round;
        if (
            !isWithdraw ||
            roundPricePerShare[currentRound] <= ShareMath.PLACEHOLDER_UINT
        ) {
            roundPricePerShare[currentRound] = ShareMath.pricePerShare(
                totalSupply(),
                IERC20(vaultParams.asset).balanceOf(address(this)),
                vaultState.totalPending,
                vaultParams.decimals
            );
        }
    }

    /************************************************
     *  SETTERS
     ***********************************************/

    /**
     * @notice Sets the new % allocation of funds towards options purchases (2 decimals. ex: 10 * 10**2 is 10%)
     * 0 < newOptionAllocation < 1000. 1000 = 10%.
     * @param newOptionAllocation is the option % allocation
     */
    function setOptionAllocation(uint16 newOptionAllocation)
        external
        onlyOwner
    {
        // Needs to be less than 10%
        require(
            newOptionAllocation > 0 &&
                newOptionAllocation < 10 * Vault.OPTION_ALLOCATION_MULTIPLIER,
            "Invalid allocation"
        );

        // emit NewOptionAllocationSet(optionAllocation, newOptionAllocation);

        optionAllocation = newOptionAllocation;
    }

    /************************************************
     *  VAULT OPERATIONS
     ***********************************************/

    /**
     * @notice Withdraws the assets on the vault using the outstanding `DepositReceipt.amount`
     * @param share is the amount to withdraw
     */
    function withdrawInstantly(uint256 share) public nonReentrant {
        require(share > 0, "!numShares");

        updatePPS(true);

        (uint256 sharesToWithdrawFromPending, uint256 sharesLeftForWithdrawal) =
            _withdrawFromNewDeposit(share);

        // Withdraw shares from pending amount
        if (sharesToWithdrawFromPending > 0) {
            vaultState.totalPending = uint128(
                uint256(vaultState.totalPending).sub(
                    sharesToWithdrawFromPending
                )
            );
        }
        uint256 currentRound = vaultState.round;

        // If we need to withdraw beyond current round deposit
        if (sharesLeftForWithdrawal > 0) {
            (uint256 heldByAccount, uint256 heldByVault) =
                shareBalances(msg.sender);

            require(
                sharesLeftForWithdrawal <= heldByAccount.add(heldByVault),
                "Insufficient balance"
            );

            if (heldByAccount < sharesLeftForWithdrawal) {
                // Redeem all shares custodied by vault to user
                _redeem(0, true);
            }

            // Burn shares
            _burn(msg.sender, sharesLeftForWithdrawal);
        }

        // emit InstantWithdraw(msg.sender, share, currentRound);

        uint256 withdrawAmount =
            ShareMath.sharesToAsset(
                share,
                roundPricePerShare[currentRound],
                vaultParams.decimals
            );
        transferAsset(msg.sender, withdrawAmount);
    }

    // @TODO commitAndClose

    /**
     * @notice Rolls the vault's funds into a new long position.
     * @param putOptionPremium is the premium per token to pay in `asset` for the put vault.
     * @param callOptionPremium is the premium per token to pay in `asset` for the call vault.
       Same decimals as `asset` (ex: 1 * 10 ** 8 means 1 WBTC per oToken)
     */
    function rollToNextOption(uint256 putOptionPremium, uint256 callOptionPremium)
    external
    onlyKeeper
    nonReentrant {
        (address newOption, uint256 lockedBalance) = _rollToNextOption();

        balanceBeforePremium = lockedBalance;

        GnosisAuction.BidDetails memory bidDetails;

        // bidding on counterpartyPutThetaVault
        bidDetails.auctionId = counterpartyPutThetaVault.optionAuctionID();
        bidDetails.gnosisEasyAuction = GNOSIS_EASY_AUCTION;
        bidDetails.oTokenAddress = newOption;
        bidDetails.asset = vaultParams.asset;
        bidDetails.assetDecimals = vaultParams.decimals;
        bidDetails.lockedBalance = lockedBalance;
        bidDetails.optionAllocation = optionAllocation;
        bidDetails.optionPremium = putOptionPremium;
        bidDetails.bidder = msg.sender;

        // place bid
        (uint256 putSellAmount, uint256 putBuyAmount, uint64 putUserId) =
        VaultLifecycle.placeBid(bidDetails);

        auctionPutSellOrder.sellAmount = uint96(putSellAmount);
        auctionPutSellOrder.buyAmount = uint96(putBuyAmount);
        auctionPutSellOrder.userId = putUserId;

        // bidding on counterpartyCallThetaVault
        bidDetails.auctionId = counterpartyCallThetaVault.optionAuctionID();
        bidDetails.gnosisEasyAuction = GNOSIS_EASY_AUCTION;
        bidDetails.oTokenAddress = newOption;
        bidDetails.asset = vaultParams.asset;
        bidDetails.assetDecimals = vaultParams.decimals;
        bidDetails.lockedBalance = lockedBalance;
        bidDetails.optionAllocation = optionAllocation;
        bidDetails.optionPremium = callOptionPremium;
        bidDetails.bidder = msg.sender;

        // place bid
        (uint256 callSellAmount, uint256 callBuyAmount, uint64 callUserId) =
        VaultLifecycle.placeBid(bidDetails);

        auctionCallSellOrder.sellAmount = uint96(callSellAmount);
        auctionCallSellOrder.buyAmount = uint96(callBuyAmount);
        auctionCallSellOrder.userId = callUserId;

        updatePPS(false);

        // emit OpenLong(newOption, buyAmount, sellAmount, msg.sender);
    }

    /**
     * @notice Claims the delta vault's oTokens from the put vault counterparty
     */
    function _claimPutVaultAuctionOtokens() internal nonReentrant {
        VaultLifecycle.claimAuctionOtokens(
            auctionPutSellOrder,
            GNOSIS_EASY_AUCTION,
            address(counterpartyPutThetaVault)
        );
        updatePPS(false);
    }

    /**
     * @notice Claims the delta vault's oTokens from the call vault counterparty
     */
    function _claimCallVaultAuctionOtokens() internal nonReentrant {
        VaultLifecycle.claimAuctionOtokens(
            auctionCallSellOrder,
            GNOSIS_EASY_AUCTION,
            address(counterpartyCallThetaVault)
        );
        updatePPS(false);
    }

    /**
     * @notice Claims the long stangle vault's oTokens from latest auction
     */
    function claimAuctionOtokens() external nonReentrant {
        _claimPutVaultAuctionOtokens();
        _claimCallVaultAuctionOtokens();
    }

        /**
     * @notice Withdraws from the most recent deposit which has not been processed
     * @param share is how many shares to withdraw in total
     * @return the shares to remove from pending
     * @return the shares left to withdraw
     */
    function _withdrawFromNewDeposit(uint256 share)
        private
        returns (uint256, uint256)
    {
        Vault.DepositReceipt storage depositReceipt =
            depositReceipts[msg.sender];

        // Immediately get what is in the pending deposits, without need for checking pps
        if (
            depositReceipt.round == vaultState.round &&
            depositReceipt.amount > 0
        ) {
            uint256 receiptShares =
                ShareMath.assetToShares(
                    depositReceipt.amount,
                    roundPricePerShare[depositReceipt.round],
                    vaultParams.decimals
                );
            uint256 sharesWithdrawn = Math.min(receiptShares, share);
            // Subtraction underflow checks already ensure it is smaller than uint104
            depositReceipt.amount = uint104(
                ShareMath.sharesToAsset(
                    uint256(receiptShares).sub(sharesWithdrawn),
                    roundPricePerShare[depositReceipt.round],
                    vaultParams.decimals
                )
            );
            return (sharesWithdrawn, share.sub(sharesWithdrawn));
        }

        return (0, share);
    }

    // /************************************************
    //  *  GETTERS
    //  ***********************************************/

    // /**
    //  * @notice Returns the vault's total balance, including the amounts locked into a short position
    //  * @return total balance of the vault, including the amounts locked in third party protocols
    //  */
    // function totalBalance() public view override virtual returns (uint256) {
    //     return
    //         uint256(vaultState.lockedAmount).add(
    //             IERC20(vaultParams.asset).balanceOf(address(this))
    //         );
    // }
}