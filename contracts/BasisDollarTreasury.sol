// SPDX-License-Identifier: MIT
/**
 *Treasury合约中BasisDollar相对于BasisCash的修改：
 *在BasisCash基础上增加了许多货币政策管理的细节，如：
 *限制单次增发比例：前14 epochs单次固定增发比例为9%，其余次增发比例最高不超过4.5%,除非国库储备量小于bond总供应量
 *根据bond的供应量，调整增发量，且调整给国库和董事会的比例:
 *    1.国库储备量>bond供应量时，最高增发4.5%，且全部增发至董事会
 *    2.国库储备量<bond供应量时，最高增发9%，增发数量35%归董事会，剩下的到国库储备
 *增发给董事会的数量中，25%归lp，75%归share抵押者
 *等等  每次提议管理员都可对货币政策进行灵活修改，更加细致
 */

pragma solidity 0.6.12;

import '@openzeppelin/contracts/math/Math.sol';
import '@openzeppelin/contracts/token/ERC20/IERC20.sol';
import '@openzeppelin/contracts/token/ERC20/SafeERC20.sol';
import '@openzeppelin/contracts/utils/ReentrancyGuard.sol';

import './lib/Babylonian.sol';
import './owner/Operator.sol';
import './utils/ContractGuard.sol';
import './interfaces/IBasisAsset.sol';
import './interfaces/IOracle.sol';
import './interfaces/IBoardroom.sol';

/**
 * @title Basis Dollar Treasury contract
 * @notice Monetary policy logic to adjust supplies of basis dollar assets
 * @author Summer Smith & Rick Sanchez
 */
contract Treasury is ContractGuard {
    using SafeERC20 for IERC20;
    using Address for address;
    using SafeMath for uint256;

    /* ========= CONSTANT VARIABLES ======== */

    uint256 public constant PERIOD = 12 hours; ////////////////////////////////////

    /* ========== STATE VARIABLES ========== */

    // governance
    address public operator;

    // flags
    bool public migrated = false;
    bool public initialized = false;

    // epoch
    uint256 public startTime;
    uint256 public epoch = 0;
    uint256 public epochSupplyContractionLeft = 0;

    // core components
    address public dollar = address(0x003e0af2916e598Fa5eA5Cb2Da4EDfdA9aEd9Fde);
    address public bond = address(0xE7C9C188138f7D70945D420d75F8Ca7d8ab9c700);
    address public share = address(0x9f48b2f14517770F2d238c787356F3b961a6616F);

    address public boardroom;
    address public dollarOracle;

    // price
    uint256 public dollarPriceOne;
    uint256 public dollarPriceCeiling;

    uint256 public seigniorageSaved;

    // protocol parameters - https://docs.basisdollar.fi/ProtocolParameters
    uint256 public maxSupplyExpansionPercent;
    uint256 public bondDepletionFloorPercent;
    uint256 public seigniorageExpansionFloorPercent;
    uint256 public maxSupplyContractionPercent;
    uint256 public maxDeptRatioPercent;

    /* =================== BDIPs (BasisDollar Improvement Proposals) =================== */

    // BDIP01
    uint256 public bdip01SharedIncentiveForLpEpochs;
    uint256 public bdip01SharedIncentiveForLpPercent;
    address[] public bdip01LiquidityPools;

    // BDIP02
    uint256 public bdip02BootstrapEpochs;
    uint256 public bdip02BootstrapSupplyExpansionPercent;

    /* =================== Events =================== */

    event Initialized(address indexed executor, uint256 at);
    event Migration(address indexed target);
    event RedeemedBonds(address indexed from, uint256 amount);
    event BoughtBonds(address indexed from, uint256 amount);
    event TreasuryFunded(uint256 timestamp, uint256 seigniorage);
    event BoardroomFunded(uint256 timestamp, uint256 seigniorage);

    /* =================== Modifier =================== */

    modifier onlyOperator() {
        require(operator == msg.sender, 'Treasury: caller is not the operator');
        _;
    }

    modifier checkCondition {
        require(!migrated, 'Treasury: migrated');
        require(now >= startTime, 'Treasury: not started yet');

        _;
    }

    modifier checkEpoch {
        require(now >= nextEpochPoint(), 'Treasury: not opened yet');

        _;

        epoch = epoch.add(1);
        epochSupplyContractionLeft = IERC20(dollar)
            .totalSupply()
            .mul(maxSupplyContractionPercent)
            .div(10000);
    }

    modifier checkOperator {
        require(
            IBasisAsset(dollar).operator() == address(this) &&
                IBasisAsset(bond).operator() == address(this) &&
                IBasisAsset(share).operator() == address(this) &&
                Operator(boardroom).operator() == address(this),
            'Treasury: need more permission'
        );

        _;
    }

    modifier notInitialized {
        require(!initialized, 'Treasury: already initialized');

        _;
    }

    /* ========== VIEW FUNCTIONS ========== */

    // flags
    function isMigrated() public view returns (bool) {
        return migrated;
    }

    function isInitialized() public view returns (bool) {
        return initialized;
    }

    // epoch
    function nextEpochPoint() public view returns (uint256) {
        return startTime.add(epoch.mul(PERIOD));
    }

    // oracle
    function getDollarPrice() public view returns (uint256 dollarPrice) {
        try IOracle(dollarOracle).consult(dollar, 1e18) returns (
            uint256 price
        ) {
            return price;
        } catch {
            revert('Treasury: failed to consult dollar price from the oracle');
        }
    }

    // budget
    function getReserve() public view returns (uint256) {
        return seigniorageSaved;
    }

    /* ========== GOVERNANCE ========== */

    function initialize(
        address _dollar,
        address _bond,
        address _share,
        uint256 _startTime
    ) public notInitialized {
        dollar = _dollar; ////
        bond = _bond; ///
        share = _share; ///
        startTime = _startTime; ///

        dollarPriceOne = 10**18; ///
        dollarPriceCeiling = dollarPriceOne.mul(105).div(100); ///

        //限制BAC单次增发比例上限为4.5%
        maxSupplyExpansionPercent = 450; // Upto 4.5% supply for expansion
        bondDepletionFloorPercent = 10000; // 100% of Bond supply for depletion floor
        //单次增发的BAC至少35%比例给到董事会
        seigniorageExpansionFloorPercent = 3500; // At least 35% of expansion reserved for boardroom
        //销毁BSD换取BSDB时，单次至多占BAC供应量的4.5%,暂时没用到，待以后使用
        maxSupplyContractionPercent = 450; // Upto 4.5% supply for contraction (to burn BSD and mint BSDB)
        //至多35%的BSDB可于市面上流通购买，暂时没用到，待以后使用
        maxDeptRatioPercent = 3500; // Upto 35% supply of BSDB to purchase

        // BDIP01: 75% of X $BSD from expansion to BSDS stakers and 25% to LPs for 14 epochs
        //前14 epochs，增发的dollar的75%给到Share的抵押者，25%给到lp
        bdip01SharedIncentiveForLpEpochs = 14;
        bdip01SharedIncentiveForLpPercent = 2500;
        //4个lp池子
        bdip01LiquidityPools = [
            address(0x71661297e9784f08fd5d840D4340C02e52550cd9), // DAI/BSD
            address(0x9E7a4f7e4211c0CE4809cE06B9dDA6b95254BaaC), // USDC/BSD
            address(0xc259bf15BaD4D870dFf1FE1AAB450794eB33f8e8), // DAI/BSDS
            address(0xE0e7F7EB27CEbCDB2F1DA5F893c429d0e5954468) // USDC/BSDS
        ];

        // BDIP02: 14 first epochs with 9% max expansion
        // 提议02：前14个epochs单次增发比例上限为9%
        bdip02BootstrapEpochs = 14;
        bdip02BootstrapSupplyExpansionPercent = 900;

        // set seigniorageSaved to it's balance
        seigniorageSaved = IERC20(dollar).balanceOf(address(this));

        initialized = true;
        operator = msg.sender;
        emit Initialized(msg.sender, block.number);
    }

    function setOperator(address _operator) external onlyOperator {
        operator = _operator;
    }

    function setBoardroom(address _boardroom) external onlyOperator {
        boardroom = _boardroom;
    }

    function setDollarOracle(address _dollarOracle) external onlyOperator {
        dollarOracle = _dollarOracle;
    }

    function setDollarPriceCeiling(uint256 _dollarPriceCeiling)
        external
        onlyOperator
    {
        require(
            _dollarPriceCeiling >= dollarPriceOne &&
                _dollarPriceCeiling <= dollarPriceOne.mul(120).div(100),
            'out of range'
        ); // [$1.0, $1.2]
        dollarPriceCeiling = _dollarPriceCeiling;
    }

    function setMaxSupplyExpansionPercent(uint256 _maxSupplyExpansionPercent)
        external
        onlyOperator
    {
        require(
            _maxSupplyExpansionPercent >= 10 &&
                _maxSupplyExpansionPercent <= 1500,
            'out of range'
        ); // [0.1%, 15%]
        maxSupplyExpansionPercent = _maxSupplyExpansionPercent;
    }

    function setBondDepletionFloorPercent(uint256 _bondDepletionFloorPercent)
        external
        onlyOperator
    {
        require(
            _bondDepletionFloorPercent >= 500 &&
                _bondDepletionFloorPercent <= 10000,
            'out of range'
        ); // [5%, 100%]
        bondDepletionFloorPercent = _bondDepletionFloorPercent;
    }

    function setMaxSupplyContractionPercent(
        uint256 _maxSupplyContractionPercent
    ) external onlyOperator {
        require(
            _maxSupplyContractionPercent >= 100 &&
                _maxSupplyContractionPercent <= 1500,
            'out of range'
        ); // [0.1%, 15%]
        maxSupplyContractionPercent = _maxSupplyContractionPercent;
    }

    function setMaxDeptRatioPercent(uint256 _maxDeptRatioPercent)
        external
        onlyOperator
    {
        require(
            _maxDeptRatioPercent >= 1000 && _maxDeptRatioPercent <= 10000,
            'out of range'
        ); // [10%, 100%]
        maxDeptRatioPercent = _maxDeptRatioPercent;
    }

    function setBDIP01(
        uint256 _bdip01SharedIncentiveForLpEpochs,
        uint256 _bdip01SharedIncentiveForLpPercent,
        address[] memory _bdip01LiquidityPools
    ) external onlyOperator {
        require(
            _bdip01SharedIncentiveForLpEpochs <= 730,
            '_bdip01SharedIncentiveForLpEpochs: out of range'
        ); // <= 1 year
        require(
            _bdip01SharedIncentiveForLpPercent <= 10000,
            '_bdip01SharedIncentiveForLpPercent: out of range'
        ); // [0%, 100%]
        bdip01SharedIncentiveForLpEpochs = _bdip01SharedIncentiveForLpEpochs;
        bdip01SharedIncentiveForLpPercent = _bdip01SharedIncentiveForLpPercent;
        bdip01LiquidityPools = _bdip01LiquidityPools;
    }

    function setBDIP02(
        uint256 _bdip02BootstrapEpochs,
        uint256 _bdip02BootstrapSupplyExpansionPercent
    ) external onlyOperator {
        require(
            _bdip02BootstrapEpochs <= 60,
            '_bdip02BootstrapEpochs: out of range'
        ); // <= 1 month
        require(
            _bdip02BootstrapSupplyExpansionPercent >= 100 &&
                _bdip02BootstrapSupplyExpansionPercent <= 1500,
            '_bdip02BootstrapSupplyExpansionPercent: out of range'
        ); // [1%, 15%]
        bdip02BootstrapEpochs = _bdip02BootstrapEpochs;
        bdip02BootstrapSupplyExpansionPercent = _bdip02BootstrapSupplyExpansionPercent;
    }

    function migrate(address target) external onlyOperator checkOperator {
        require(!migrated, 'Treasury: migrated');

        // dollar
        Operator(dollar).transferOperator(target);
        Operator(dollar).transferOwnership(target);
        IERC20(dollar).transfer(
            target,
            IERC20(dollar).balanceOf(address(this))
        );

        // bond
        Operator(bond).transferOperator(target);
        Operator(bond).transferOwnership(target);
        IERC20(bond).transfer(target, IERC20(bond).balanceOf(address(this)));

        // share
        Operator(share).transferOperator(target);
        Operator(share).transferOwnership(target);
        IERC20(share).transfer(target, IERC20(share).balanceOf(address(this)));

        migrated = true;
        emit Migration(target);
    }

    /* ========== MUTABLE FUNCTIONS ========== */

    function _updateDollarPrice() internal {
        try IOracle(dollarOracle).update()  {} catch {}
    }

    function buyBonds(uint256 amount, uint256 targetPrice)
        external
        onlyOneBlock
        checkCondition
        checkOperator
    {
        require(amount > 0, 'Treasury: cannot purchase bonds with zero amount');

        uint256 dollarPrice = getDollarPrice();
        require(dollarPrice == targetPrice, 'Treasury: dollar price moved');
        require(
            dollarPrice < dollarPriceOne, // price < $1
            'Treasury: dollarPrice not eligible for bond purchase'
        );

        require(
            amount <= epochSupplyContractionLeft,
            'Treasury: not enough bond left to purchase'
        );

        uint256 _boughtBond = amount.mul(1e18).div(dollarPrice);
        uint256 dollarSupply = IERC20(dollar).totalSupply();
        uint256 newBondSupply = IERC20(bond).totalSupply().add(_boughtBond);
        require(
            newBondSupply <= dollarSupply.mul(maxDeptRatioPercent).div(10000),
            'over max debt ratio'
        );

        IBasisAsset(dollar).burnFrom(msg.sender, amount);
        IBasisAsset(bond).mint(msg.sender, _boughtBond);

        epochSupplyContractionLeft = epochSupplyContractionLeft.sub(amount);
        _updateDollarPrice();

        emit BoughtBonds(msg.sender, amount);
    }

    function redeemBonds(uint256 amount, uint256 targetPrice)
        external
        onlyOneBlock
        checkCondition
        checkOperator
    {
        require(amount > 0, 'Treasury: cannot redeem bonds with zero amount');

        uint256 dollarPrice = getDollarPrice();
        require(dollarPrice == targetPrice, 'Treasury: dollar price moved');
        require(
            dollarPrice > dollarPriceCeiling, // price > $1.05
            'Treasury: dollarPrice not eligible for bond purchase'
        );
        require(
            IERC20(dollar).balanceOf(address(this)) >= amount,
            'Treasury: treasury has no more budget'
        );

        seigniorageSaved = seigniorageSaved.sub(
            Math.min(seigniorageSaved, amount)
        );

        IBasisAsset(bond).burnFrom(msg.sender, amount);
        IERC20(dollar).safeTransfer(msg.sender, amount);

        _updateDollarPrice();

        emit RedeemedBonds(msg.sender, amount);
    }

    /**
     *@notice 把铸币发放到董事会
     */
    function _sendToBoardRoom(uint256 _amount) internal {
        //铸造董事会新增的dollar数量
        IBasisAsset(dollar).mint(address(this), _amount);
        if (epoch < bdip01SharedIncentiveForLpEpochs) {
            //前14 Epochs, 新增发dollar的25%给到lp
            uint256 _addedPoolReward = _amount
                .mul(bdip01SharedIncentiveForLpPercent)
                .div(40000);
            for (uint256 i = 0; i < 4; i++) {
                IERC20(dollar).transfer(
                    bdip01LiquidityPools[i],
                    _addedPoolReward
                );
                //已发放给lp的数量需要减掉
                _amount = _amount.sub(_addedPoolReward);
            }
        }
        IERC20(dollar).safeApprove(boardroom, _amount);
        //调用Boardroom合约的allocateSeigniorage方法,把剩下的75%分配给share抵押者
        IBoardroom(boardroom).allocateSeigniorage(_amount);
        //触发发放董事会事件
        emit BoardroomFunded(now, _amount);
    }

    /**
     *@notice 分配铸币方法
     */
    function allocateSeigniorage()
        external
        onlyOneBlock
        checkCondition
        checkEpoch
        checkOperator
    {
        _updateDollarPrice();
        //dollar的流通量 = 总供应量 - 总储备量
        uint256 dollarSupply = IERC20(dollar).totalSupply().sub(
            seigniorageSaved
        );
        // BDIP02: 14 first epochs with 9% max expansion
        if (epoch < bdip02BootstrapEpochs) {
            //在前14 epochs的增发模式:dollar新增发量 = dollar的流通量 * 9%,且不要求dollar价格
            _sendToBoardRoom(
                dollarSupply.mul(bdip02BootstrapSupplyExpansionPercent).div(
                    10000
                )
            );
        } else {
            uint256 dollarPrice = getDollarPrice();
            if (dollarPrice > dollarPriceCeiling) {
                //要求dollar价格大于1.05
                // Expansion ($BSD Price > 1$): there is some seigniorage to be allocated
                uint256 bondSupply = IERC20(bond).totalSupply();
                //增发比例 = dollar价格 - 1
                uint256 _percentage = dollarPrice.sub(dollarPriceOne);
                uint256 _savedForBond;
                uint256 _savedForBoardRoom;
                //当dollar储备量大于bond总供应量*100%时,限制最大增发比例4.5%,且全部增发给董事会
                if (
                    seigniorageSaved >=
                    bondSupply.mul(bondDepletionFloorPercent).div(10000)
                ) {
                    // saved enough to pay dept, mint as usual rate
                    uint256 _mse = maxSupplyExpansionPercent.mul(1e14);
                    if (_percentage > _mse) {
                        //限制最大增发比例4.5%
                        _percentage = _mse;
                    }
                    //董事会新增储备量
                    _savedForBoardRoom = dollarSupply.mul(_percentage).div(
                        1e18
                    );
                } else {
                    // have not saved enough to pay dept, mint double
                    //当dollar储备量小于bond总供应量*100%时,限制最大增发比例4.5%*2=9%，35%增发给董事会，剩下的增发给国库储备,以应对未来可能bond的兑换
                    uint256 _mse = maxSupplyExpansionPercent.mul(2e14);
                    if (_percentage > _mse) {
                        _percentage = _mse;
                    }
                    uint256 _seigniorage = dollarSupply.mul(_percentage).div(
                        1e18
                    );
                    //新增发的dollar中35%给到董事会
                    _savedForBoardRoom = _seigniorage
                        .mul(seigniorageExpansionFloorPercent)
                        .div(10000);
                    //剩下的给到国库的储备，以应对未来可能bond的兑换
                    _savedForBond = _seigniorage.sub(_savedForBoardRoom);
                }
                if (_savedForBoardRoom > 0) {
                    //如果董事会新增储备量大于0，则把新增数量发送到董事会
                    _sendToBoardRoom(_savedForBoardRoom);
                }
                if (_savedForBond > 0) {
                    //如果新增国库储备数量大于0，则把新增数量加入到国库总储备量中
                    seigniorageSaved = seigniorageSaved.add(_savedForBond);
                    //铸造国库储备中新增的dollar
                    IBasisAsset(dollar).mint(address(this), _savedForBond);
                    //触发发送国库事件
                    emit TreasuryFunded(now, _savedForBond);
                }
            }
        }
    }
}
