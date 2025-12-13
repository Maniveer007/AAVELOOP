// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IERC20, IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {IPool} from "@aave/core-v3/contracts/interfaces/IPool.sol";
import {IAaveOracle} from "@aave/core-v3/contracts/interfaces/IAaveOracle.sol";
import {IPoolAddressesProvider} from "@aave/core-v3/contracts/interfaces/IPoolAddressesProvider.sol";
import {IPoolDataProvider} from "@aave/core-v3/contracts/interfaces/IPoolDataProvider.sol";
import '@reactive-lib/src/abstract-base/AbstractCallback.sol';


interface IUniswapV2Router02 {
    function swapExactTokensForTokens(
        uint256 amountIn,
        uint256 amountOutMin,
        address[] calldata path,
        address to,
        uint256 deadline
    ) external returns (uint256[] memory amounts);
}

contract AaveLoop is AbstractCallback{
    address public immutable owner;
    address public immutable reactiveCallback;

    IPool public immutable pool;
    IAaveOracle public immutable oracle;
    IPoolDataProvider public immutable dataProvider;

    IUniswapV2Router02 public immutable uniswapRouter;
    address public immutable usdc;

    IERC20Metadata public asset;

    struct LoopConfig {
        uint16 borrowBps;
        uint256 minBorrowAmount;
        uint16 maxSlippageBps;
        uint256 minHealthFactor;
        uint256 targetTvl; // target TVL expressed in asset token units (i.e., same decimals as `asset`)
    }

    LoopConfig public loopConfig;

    // Events
    event LoopStarted(
        address asset,
        uint256 supplyAmount,
        uint16 borrowBps,
        uint256 minBorrowAmount,
        uint16 maxSlippageBps,
        uint256 minHealthFactor,
        uint256 targetTvl
    );
    event LoopIterated(uint256 iterationCollateralBase_inAssetTokens, uint256 iterationDebtBase_inAssetTokens);

    modifier onlyOwner() {
        require(msg.sender == owner, "NOT_OWNER");
        _;
    }

    modifier onlyReactive() {
        require(msg.sender == reactiveCallback, "NOT_REACTIVE");
        _;
    }

    constructor(
        address _addressesProvider,
        address _usdc,
        address _uniswapRouter,
        address _reactiveCallback
    ) AbstractCallback(_reactiveCallback) payable {
        require(_addressesProvider != address(0), "BAD_PROVIDER");
        require(_usdc != address(0), "BAD_USDC");
        require(_uniswapRouter != address(0), "BAD_ROUTER");
        require(_reactiveCallback != address(0), "BAD_CALLBACK");

        owner = msg.sender;
        reactiveCallback = _reactiveCallback;

        IPoolAddressesProvider provider = IPoolAddressesProvider(_addressesProvider);
        pool = IPool(provider.getPool());
        oracle = IAaveOracle(provider.getPriceOracle());
        dataProvider = IPoolDataProvider(provider.getPoolDataProvider());

        usdc = _usdc;
        uniswapRouter = IUniswapV2Router02(_uniswapRouter);
    }

    // ------------------------------- USER ENTRY -------------------------------

    // Note: added `targetTvl` as the last parameter (expressed in asset token units, with same decimals as `asset`)
    function supplyAndLoop(
        address asset_,
        uint256 supplyAmount,
        uint16 borrowBps,
        uint256 minBorrowAmount,
        uint16 maxSlippageBps,
        uint256 minHealthFactor,
        uint256 targetTvl
    ) external onlyOwner {
        require(asset_ != address(0), "ASSET_ZERO");
        require(supplyAmount > 0, "SUPPLY_ZERO");
        require(maxSlippageBps <= 10000, "SLIPPAGE_BAD");

        IERC20Metadata assetToken = IERC20Metadata(asset_);

        // reserve config check
        (, uint256 ltv, , , , , , , , bool isFrozen) =
            dataProvider.getReserveConfigurationData(asset_);

        require(!isFrozen, "FROZEN");
        require(ltv > 0, "NOT_SUPPORTED");

        asset = assetToken;

        require(IERC20(asset_).transferFrom(msg.sender, address(this), supplyAmount), "TF_FAIL");
        require(IERC20(asset_).approve(address(pool), supplyAmount), "APPROVE_FAIL");

        pool.supply(asset_, supplyAmount, address(this), 0);

        loopConfig = LoopConfig({
            borrowBps: borrowBps,
            minBorrowAmount: minBorrowAmount,
            maxSlippageBps: maxSlippageBps,
            minHealthFactor: minHealthFactor,
            targetTvl: targetTvl
        });

        emit LoopStarted(
            asset_,
            supplyAmount,
            borrowBps,
            minBorrowAmount,
            maxSlippageBps,
            minHealthFactor,
            targetTvl
        );
    }

    function withdraw() external onlyOwner {
        require(address(asset) != address(0), "NO_ASSET");
        (
            ,
            uint256 totalDebtBase,
            ,
            ,
            ,
            
        ) = pool.getUserAccountData(address(this));
        if (totalDebtBase > 0) {
            uint256 priceA = oracle.getAssetPrice(address(asset));
            require(priceA > 0, "BAD_PRICE");
            uint8 assetDecimals = IERC20Metadata(address(asset)).decimals();
            uint256 debtInAsset = (totalDebtBase * (10 ** assetDecimals)) / priceA;
            if (debtInAsset == 0) {
                debtInAsset = 1;
            }
            IERC20(address(asset)).transferFrom(owner, address(this), debtInAsset);
            IERC20(address(asset)).approve(address(pool), debtInAsset);
            pool.repay(address(asset), debtInAsset, 2, address(this));
        }
        uint256 withdrawn = pool.withdraw(address(asset), type(uint256).max, address(this));
        IERC20(address(asset)).transfer(owner, withdrawn);

    }

    function withdrawEth() public onlyOwner {
        payable(msg.sender).transfer(address(this).balance);
    }


    // --------------------------- REACTIVE CALLBACK ----------------------------

function onReactiveCallback(address) external onlyReactive {
    LoopConfig memory cfg = loopConfig;
    require(address(asset) != address(0), "NO_ASSET");

    // get account data
    (,, uint256 availableBorrowsBase, , , ) =
        pool.getUserAccountData(address(this));

    uint256 plannedBorrowBase = (availableBorrowsBase * cfg.borrowBps) / 10000;

    (,,,,,, bool borrowingEnabled,,, ) =
        dataProvider.getReserveConfigurationData(address(asset));

    uint256 borrowAmountInAsset = 0;

    // -------------------------------------------------------------
    // CASE 1: DIRECT ASSET BORROW
    // -------------------------------------------------------------
    if (borrowingEnabled) {
        uint256 priceA = oracle.getAssetPrice(address(asset));
        require(priceA > 0, "BAD_PRICE_A");

        borrowAmountInAsset =
            plannedBorrowBase * (10 ** asset.decimals()) / priceA;

        if (borrowAmountInAsset < cfg.minBorrowAmount) return;

        pool.borrow(address(asset), borrowAmountInAsset, 2, 0, address(this));
        IERC20(address(asset)).approve(address(pool), borrowAmountInAsset);
        pool.supply(address(asset), borrowAmountInAsset, address(this), 0);
    }

    // -------------------------------------------------------------
    // CASE 2: FALLBACK — BORROW USDC → SWAP → SUPPLY ASSET
    // -------------------------------------------------------------
    else {
        uint256 priceU = oracle.getAssetPrice(usdc);
        require(priceU > 0, "BAD_PRICE_U");

        uint8 usdcDec = IERC20Metadata(usdc).decimals();
        uint256 borrowAmountUSDC =
            plannedBorrowBase * (10 ** usdcDec) / priceU;

        if (borrowAmountUSDC < cfg.minBorrowAmount) return;

        pool.borrow(usdc, borrowAmountUSDC, 2, 0, address(this));
        IERC20(usdc).approve(address(uniswapRouter), borrowAmountUSDC);

        uint256 priceA2 = oracle.getAssetPrice(address(asset));
        require(priceA2 > 0, "BAD_PRICE_A2");

        uint256 expectedOut =
            plannedBorrowBase * (10 ** asset.decimals()) / priceA2;

        uint256 minOut =
            expectedOut * (10000 - cfg.maxSlippageBps) / 10000;

        address[] memory path;
        path[0] = usdc;
        path[1] = address(asset);

        uint256 before = IERC20(address(asset)).balanceOf(address(this));

        uniswapRouter.swapExactTokensForTokens(
            borrowAmountUSDC,
            minOut,
            path,
            address(this),
            block.timestamp + 300
        );

        uint256 afterBal = IERC20(address(asset)).balanceOf(address(this));
        borrowAmountInAsset = afterBal > before ? afterBal - before : 0;

        IERC20(address(asset)).approve(address(pool), borrowAmountInAsset);
        pool.supply(address(asset), borrowAmountInAsset, address(this), 0);
    }

    // -------------------------------------------------------------
    // AFTER SUPPLY: Get latest collateral + debt and convert to asset
    // -------------------------------------------------------------
    (
        uint256 totalCollateralBase,
        uint256 totalDebtBase,
        ,
        ,
        ,
        
    ) = pool.getUserAccountData(address(this));

    uint256 priceA3 = oracle.getAssetPrice(address(asset));
    require(priceA3 > 0, "BAD_PRICE_3");
    uint8 dec = asset.decimals();

    uint256 collateralInAsset =
        (totalCollateralBase * (10 ** dec)) / priceA3;

    uint256 debtInAsset =
        (totalDebtBase * (10 ** dec)) / priceA3;

    // -------------------------------------------------------------
    // EMIT LOOP ITERATED
    // -------------------------------------------------------------
    emit LoopIterated(collateralInAsset, debtInAsset);

    // -------------------------------------------------------------
    // FINAL HF CHECK
    // -------------------------------------------------------------
    (, , , , , uint256 newHF) = pool.getUserAccountData(address(this));
    require(newHF >= cfg.minHealthFactor, "HF_TOO_LOW");
}




    function getAccountData()
        external
        view
        returns (
            uint256 collateral,
            uint256 debt,
            uint256 borrowable,
            uint256 liqThreshold,
            uint256 ltv,
            uint256 healthFactor
        )
    {
        return pool.getUserAccountData(address(this));
    }
}
