// SPDX-License-Identifier: MIT
pragma solidity ^0.6.0;

import '@openzeppelin/contracts/token/ERC20/IERC20.sol';
import '@openzeppelin/contracts/token/ERC20/SafeERC20.sol';
import '@openzeppelin/contracts/math/Math.sol';

import './interfaces/IOracle.sol';
import './interfaces/IBoardroom.sol';
import './interfaces/IBasisAsset.sol';
import './interfaces/ISimpleERCFund.sol';
import './interfaces/ITreasury.sol';
import './interfaces/IRewardPool.sol';
import './lib/FixedPoint.sol';
import './utils/Epoch.sol';
import './lib/Safe112.sol';
import './lib/AdminRole.sol';
import './utils/ContractGuard.sol';

/**
 * @title GoCash Cash Treasury合约
 * 实现功能：
 * 1.通过预言机获取GOC价格，根据GOC价格不同，用GOC购买GOB，或赎回GOB获得GOC
 * 2.根据GOC价格不同，增发GOC，并把新增发的GOC分配给fund treasury shareBoardroom
 * 注解：TimBear 20210107
 * @notice Monetary policy logic to adjust supplies of basis cash assets
 * @author Summer Smith & Rick Sanchez
 */
contract Treasury is ContractGuard, Epoch {
    using FixedPoint for *;
    using SafeERC20 for IERC20;
    using Address for address;
    using SafeMath for uint256;
    using Safe112 for uint112;

    /* ========== STATE VARIABLES ========== */

    // ========== FLAGS 标记
    /// @notice 已迁移
    bool public migrated = false;
    /// @notice 已初始化
    bool public initialized = false;

    // ========== CORE 核心
    /// @notice 开发者基金
    address public fund;
    /// @notice GoCash Cash地址
    address public cash;
    /// @notice GoCash Bond地址
    address public bond;
    /// @notice GoCash Token地址
    address public share;
    /// @notice share质押董事会合约地址
    address public shareBoardroom;
    /// @notice lp质押董事会合约地址
    address public lpBoardroom;
    /// @notice bond奖励池地址
    address public bondRewardPool;

    /// @notice 预言机地址
    address public oracle;

    // ========== PARAMS 参数
    /// @notice cash基准价格
    uint256 public cashPriceOne;
    /// @notice oracle基准价格
    uint256 public oraclePriceOne;
    /// @notice 价格天花板
    uint256 public cashPriceCeiling;

    /// @notice cash价格下限
    uint256 public cashPriceFloor;
    /// @notice cash价格bond奖励
    uint256 public cashPriceBondReward;
    /// @notice bond基准价格 1
    uint256 public bondPrice;
    /// @notice 最低bond价格 0.5
    uint256 public minBondPrice;
    /// @notice bondPriceDelta 0.02
    uint256 public bondPriceDelta;

    /// @dev 累计铸币税
    uint256 private accumulatedSeigniorage = 0;
    /// @notice 开发者基金分配比例 2%
    uint256 public fundAllocationRate = 2; // %

    /// @dev 累计债务
    uint256 private accumulatedDebt = 0;

    /// @notice 最大通胀率
    uint256 public maxInflationRate = 10;
    /// @notice 债务增加比率
    uint256 public debtAddRate = 2;
    /// @notice 最大债务比率
    uint256 public maxDebtRate = 20;
    // ========== MIGRATE
    /// @dev 旧国库合约地址
    address public legacyTreasury;

    /* ========== CONSTRUCTOR ========== */
    /**
     * @dev 构造函数
     * @param _cash GoCash Cash地址
     * @param _bond GoCash Bond地址
     * @param _share GoCash Token地址
     * @param _oracle Bond预言机地址
     * @param _shareBoardroom share质押董事会合约地址
     * @param _lpBoardroom lp质押董事会合约地址
     * @param _bondRewardPool bond奖励池地址
     * @param _fund 开发者基金
     * @param _startTime 开始时间
     */
    constructor(
        address _cash,
        address _bond,
        address _share,
        address _oracle,
        address _shareBoardroom,
        address _lpBoardroom,
        address _bondRewardPool,
        address _fund,
        uint256 _startTime
    ) public Epoch(12 hours, _startTime, 0) {
        cash = _cash;
        bond = _bond;
        share = _share;
        oracle = _oracle;

        shareBoardroom = _shareBoardroom;
        lpBoardroom = _lpBoardroom;
        bondRewardPool = _bondRewardPool;
        fund = _fund;

        // Cash基准价格为1
        cashPriceOne = 10**18;
        // oracle基准价格,防止有些token精度不是18
        oraclePriceOne = 10**18;
        // cash价格天花板为1.02 102 * 10**18 / 10**2 = 1.05
        cashPriceCeiling = uint256(102).mul(cashPriceOne).div(10**2);
        // band亏损下限 1000 * 10**18
        // bondDepletionFloor = uint256(1000).mul(cashPriceOne);
        // cash价格下限 98 * 10**18 / 10**2 = 0.98
        cashPriceFloor = uint256(98).mul(cashPriceOne).div(10**2);
        // cash价格bond奖励 95 * 10**18 / 10**2 = 0.98
        cashPriceBondReward = uint256(95).mul(cashPriceOne).div(10**2);
        // bond基准价格
        bondPrice = 10**18;
        // 最低bond基准价格 0.5
        minBondPrice = 5 * 10**17;
        // bond基准价Delta 0.02
        bondPriceDelta = 2 * 10**16;
    }

    /* =================== Modifier =================== */

    /// @notice 修饰符：需要完成Migration，即完成更换Admin为本合约
    modifier checkMigration {
        require(!migrated, 'Treasury: migrated');
        _;
    }

    /// @notice 修饰符：合约cash bond share boardroom的Admin必须为本合约
    modifier checkAdmin {
        require(
            AdminRole(cash).isAdmin(address(this)) &&
                AdminRole(bond).isAdmin(address(this)) &&
                AdminRole(share).isAdmin(address(this)) &&
                AdminRole(bondRewardPool).isAdmin(address(this)) &&
                AdminRole(lpBoardroom).isAdmin(address(this)) &&
                AdminRole(shareBoardroom).isAdmin(address(this)),
            'Treasury: need more permission'
        );
        _;
    }

    /* ========== VIEW FUNCTIONS ========== */
    //一些只读方法

    /**
     * @dev 返回累计铸币税,预算?
     * @return 预算
     */
    function getReserve() public view returns (uint256) {
        return accumulatedSeigniorage;
    }

    // debt
    /**
     * @dev 返回债务
     * @return 累计债务
     */
    function getDebt() public view returns (uint256) {
        return accumulatedDebt;
    }

    // oracle
    /**
     * @dev 返回预言机中Cash价格
     * @return 价格
     */
    function getOraclePrice() public view returns (uint256) {
        // 通过预言机取Cash价格
        return _getCashPrice(oracle);
    }

    /**
     * @dev 根据不同的场景选择不同的预言机进行喂价
     * @param _oracle 预言机地址
     * @return 价格
     */
    function _getCashPrice(address _oracle) internal view returns (uint256) {
        try IOracle(_oracle).consult(cash, 1e18) returns (uint256 price) {
            // 返回价格 * 1e18 / 1e18 防止有些token精度不是18
            return price.mul(cashPriceOne).div(oraclePriceOne);
        } catch {
            revert('Treasury: failed to consult cash price from the oracle');
        }
    }

    /* ========== GOVERNANCE ========== */

    /**
     * @dev 设置旧国库合约地址
     */
    function setLegacyTreasury(address _legacyTreasury) public onlyAdmin {
        legacyTreasury = _legacyTreasury;
    }

    /**
     * @dev 合约初始化
     * @param _accumulatedSeigniorage 累计铸币税
     * @param _accumulatedDebt 累计债务
     * @param _bondPrice bond基准价格
     * @param _oraclePriceOne 预言机基准价格
     */
    function initialize(
        uint256 _accumulatedSeigniorage,
        uint256 _accumulatedDebt,
        uint256 _bondPrice,
        uint256 _oraclePriceOne
    ) public {
        // 确认合约未经初始化
        require(!initialized, 'Treasury: initialized');
        // 确认必须由旧国库合约调用
        require(msg.sender == legacyTreasury, 'Treasury: on legacy treasury');
        // 变量赋值
        accumulatedSeigniorage = _accumulatedSeigniorage;
        accumulatedDebt = _accumulatedDebt;
        bondPrice = _bondPrice;
        oraclePriceOne = _oraclePriceOne;

        initialized = true;
        //触发合约初始化事件
        emit Initialized(msg.sender, block.number);
    }

    /**
     * @dev 迁移国库合约到新合约
     * @param target 目标地址
     */
    function migrate(address target) public onlyAdmin checkAdmin {
        require(!migrated, 'Treasury: migrated');

        // cash
        //更换GOC合约的Admin，Owner为target，并把原合约的GOC发送至target
        AdminRole(cash).addAdmin(target);
        AdminRole(cash).renounceAdmin();
        IERC20(cash).transfer(target, IERC20(cash).balanceOf(address(this)));

        // bond
        //更换GOB合约的Admin，Owner为target，并把原合约的GOB发送至target
        AdminRole(bond).addAdmin(target);
        AdminRole(bond).renounceAdmin();
        IERC20(bond).transfer(target, IERC20(bond).balanceOf(address(this)));

        // share
        //更换GOT合约的Admin，Owner为target，并把原合约的GOT发送至target
        AdminRole(share).addAdmin(target);
        AdminRole(share).renounceAdmin();
        IERC20(share).transfer(target, IERC20(share).balanceOf(address(this)));

        // Boardroom
        //更换boardroom合约的Admin
        AdminRole(bondRewardPool).addAdmin(target);
        AdminRole(bondRewardPool).renounceAdmin();
        AdminRole(shareBoardroom).addAdmin(target);
        AdminRole(shareBoardroom).renounceAdmin();
        AdminRole(lpBoardroom).addAdmin(target);
        AdminRole(lpBoardroom).renounceAdmin();

        // params
        ITreasury(target).initialize(
            accumulatedSeigniorage,
            accumulatedDebt,
            bondPrice,
            oraclePriceOne
        );

        migrated = true;
        //触发所有权转移事件
        emit Migration(target);
    }

    /**
     * @dev 设置开发者基金地址
     * @param newFund 新开发者基金地址
     */
    function setFund(address newFund) public onlyAdmin {
        //设置开发贡献者奖金池
        fund = newFund;
        //触发更换开发贡献者奖金池事件
        emit ContributionPoolChanged(msg.sender, newFund);
    }

    /**
     * @dev 设置开发者奖励比例
     * @param rate 新比例
     */
    function setFundAllocationRate(uint256 rate) public onlyAdmin {
        //设置开发贡献者奖金比例
        fundAllocationRate = rate;
        //触发更换开发贡献者奖金比例事件
        emit ContributionPoolRateChanged(msg.sender, rate);
    }

    /**
     * @dev 设置预言机基准价格1
     * @param _oraclePriceOne 新基准价格1
     */
    function setOraclePriceOne(uint256 _oraclePriceOne) public onlyAdmin {
        oraclePriceOne = _oraclePriceOne;
        //触发事件
        emit SetOraclePriceOne(oraclePriceOne);
    }

    /**
     * @dev 设置最大通胀比例
     * @param rate 最大通胀比例
     */
    function setMaxInflationRate(uint256 rate) public onlyAdmin {
        maxInflationRate = rate;
        emit MaxInflationRateChanged(msg.sender, rate);
    }

    /**
     * @dev 设置债务增加比率
     * @param rate 债务增加比率
     */
    function setDebtAddRate(uint256 rate) public onlyAdmin {
        debtAddRate = rate;
        emit DebtAddRateChanged(msg.sender, rate);
    }

    /**
     * @dev 设置最大债务比例
     * @param rate 最大债务比例
     */
    function setMaxDebtRate(uint256 rate) public onlyAdmin {
        maxDebtRate = rate;
        emit MaxDebtRateChanged(msg.sender, rate);
    }

    /* ========== MUTABLE FUNCTIONS ========== */

    /**
     * @dev 预言机更新GOC价格
     */
    function _updateCashPrice() internal {
        try IOracle(oracle).update()  {} catch {}
    }

    /**
     * @dev 当GOC价格低于1时，使用GOC购买GOB
     * @param amount 购买数额
     */
    function buyBonds(uint256 amount)
        external
        onlyOneBlock // 同一区块只能调用一次合约
        checkMigration // 检查是否迁移
        checkStartTime // 检查开始时间
        checkAdmin // 检查铸币权限
    {
        //通过预言机获取GOC价格
        uint256 cashPrice = _getCashPrice(oracle);
        //需要GOC价格小于1
        require(
            cashPrice < cashPriceOne, // price < $1
            'Treasury: cashPrice not eligible for bond purchase'
        );
        // 销毁数量 = 最小值(购买数量,累计债务 * bond基准价 / 1e18)
        uint256 burnAmount = Math.min(
            amount,
            accumulatedDebt.mul(bondPrice).div(1e18)
        );
        // 确认销毁数量 > 0
        require(
            burnAmount > 0,
            'Treasury: cannot purchase bonds with zero amount'
        );
        // 铸造bond数量 = 销毁数量 * 1e18 / bond基准价
        uint256 mintBondAmount = burnAmount.mul(1e18).div(bondPrice);
        //销毁用户持有的amount数量的GOC
        IBasisAsset(cash).burnFrom(msg.sender, burnAmount);
        //铸造GOB: 铸造bond数量
        IBasisAsset(bond).mint(msg.sender, mintBondAmount);
        // 累计债务 = 累计债务 - 铸造bond数量
        accumulatedDebt = accumulatedDebt.sub(mintBondAmount);

        //更新GOC价格
        _updateCashPrice();
        //触发购买GOB事件
        emit BoughtBonds(msg.sender, amount);
    }

    /**
     * @dev 当GOC价格大于1.05时，使用GOB换回GOC
     * @param amount 赎回数额
     */
    function redeemBonds(uint256 amount)
        external
        onlyOneBlock // 同一区块只能调用一次合约
        checkMigration // 检查是否迁移
        checkStartTime // 检查开始时间
        checkAdmin // 检查铸币权限
    {
        //通过预言机获取GOC价格
        uint256 cashPrice = _getCashPrice(oracle);
        // 确认GOC价格大于cashPriceCeiling，即1.02
        require(
            cashPrice > cashPriceCeiling, // price > $1.02
            'Treasury: cashPrice not eligible for bond purchase'
        );
        // 赎回数量 = 最小值(GOC的累计储备量,赎回数额)
        uint256 redeemAmount = Math.min(accumulatedSeigniorage, amount);
        // 确认赎回数量>0
        require(
            redeemAmount > 0,
            'Treasury: cannot redeem bonds with zero amount'
        );
        // 确认当前合约的GOC数量大于要赎回的GOB数量
        require(
            IERC20(cash).balanceOf(address(this)) >= redeemAmount,
            'Treasury: treasury has no more budget'
        );
        // GOC的累计储备量 = 累计储备量 - 赎回数量,即1GOB换取1GOC
        accumulatedSeigniorage = accumulatedSeigniorage.sub(redeemAmount);
        // 销毁用户持有的GOB
        IBasisAsset(bond).burnFrom(msg.sender, redeemAmount);
        // 将当前合约的GOC发送给用户
        IERC20(cash).safeTransfer(msg.sender, redeemAmount);
        // 更新GOC价格
        _updateCashPrice();
        // 触发赎回GOB事件
        emit RedeemedBonds(msg.sender, amount);
    }

    /**
     * @dev 增发GOC，并分配GOC
     */
    function allocateSeigniorage()
        external
        onlyOneBlock
        checkMigration
        checkStartTime
        checkEpoch
        checkAdmin
    {
        //更新GOC价格
        _updateCashPrice();
        //通过预言机获取GOC价格
        uint256 cashPrice = _getCashPrice(oracle);
        // circulating supply
        // 流通的GOC数量 = GOC总供应量 - GOC累计储备量
        uint256 cashSupply = IERC20(cash).totalSupply().sub(
            accumulatedSeigniorage
        );
        //判断当GOC价格小于等于cashPriceBondReward即小于0.95
        if (cashPrice <= cashPriceBondReward) {
            // 奖励数量 = bond的1%
            uint256 rewardAmount = IERC20(bond).totalSupply().div(100);
            // bond铸造奖励,发给bond奖励池
            IBasisAsset(bond).mint(bondRewardPool, rewardAmount);
            // bond奖励池通知奖励数量
            IRewardPool(bondRewardPool).notifyRewardAmount(rewardAmount);
            // 触发奖励事件
            emit BondReward(block.timestamp, rewardAmount);
        }

        // add debt
        //判断当GOC价格小于等于0.98(cash价格下限)
        if (cashPrice <= cashPriceFloor) {
            // 增加债务 = 流通的GOC数量 * 2%(债务增加比率)
            uint256 addDebt = cashSupply.mul(debtAddRate).div(100);
            // 最大债务 = 流通的GOC数量 * 20%(最大债务比率)
            uint256 maxDebt = cashSupply.mul(maxDebtRate).div(100);
            // 累计债务 = 累计债务 + 增加的债务
            accumulatedDebt = accumulatedDebt.add(addDebt);
            // 如果累计债务 > 最大债务
            if (accumulatedDebt > maxDebt) {
                // 累计债务 = 最大债务 20%
                accumulatedDebt = maxDebt;
            }
            // bond基准价 = bond基准价 - 0.02(bond基准价Delta)
            bondPrice = bondPrice.sub(bondPriceDelta);
            // 如果 bond基准价 <= 0.5(最低bond基准价格)
            if (bondPrice <= minBondPrice) {
                // bond基准价 = 0.5(最低bond基准价格)
                bondPrice = minBondPrice;
            }
        }

        // clear the debt
        // 如果GOC价格>0.98(cash价格下限)
        if (cashPrice > cashPriceFloor) {
            // 累计债务清零
            accumulatedDebt = 0;
            // bond价格=1
            bondPrice = 10**18;
        }

        //判断当GOC价格小于等于cashPriceCeiling即小于1.05则返回，不增发GOC
        if (cashPrice <= cashPriceCeiling) {
            return; // just advance epoch instead revert
        }

        //增发比例 = GOC价格 - 1 例:0.8
        uint256 percentage = cashPrice.sub(cashPriceOne);
        //新铸造的GOC数量 = 流通的GOC数量 * 增发比例
        uint256 seigniorage = cashSupply.mul(percentage).div(1e18);
        // 最大铸造的GOC数量 = 流通的GOC数量 * 10%(最大通胀比例)
        uint256 maxSeigniorage = cashSupply.mul(maxInflationRate).div(100);
        // 如果新铸造的GOC数量 > 最大铸造的GOC数量
        if (seigniorage > maxSeigniorage) {
            // 新铸造的GOC数量 = 最大铸造的GOC数量
            seigniorage = maxSeigniorage;
        }
        //新铸造GOC,并发送至本合约
        IBasisAsset(cash).mint(address(this), seigniorage);

        // ======================== BIP-3
        // 开发者基金储备 = 新铸造的GOC数量 * fundAllocationRate / 100 = 新铸造的GOC数量 * 2%
        uint256 fundReserve = seigniorage.mul(fundAllocationRate).div(100);
        if (fundReserve > 0) {
            // 当前合约批准fund地址,开发者准备金数额
            IERC20(cash).safeApprove(fund, fundReserve);
            // 调用fund合约的存款方法存入开发者准备金
            ISimpleERCFund(fund).deposit(
                cash,
                fundReserve,
                'Treasury: Seigniorage Allocation'
            );
            //触发GOC已发放至开发贡献池事件
            emit ContributionPoolFunded(now, fundReserve);
        }
        //新铸造的GOC数量 = 新铸造的GOC数量 - 开发者基金储备
        seigniorage = seigniorage.sub(fundReserve);

        // ======================== BIP-4
        //新增国库储备 = min(新铸造的GOC数量 / 2, GOB总供应量-累计GOC储备量)
        //即新铸造的GOC要先预留给GOB，剩下的才能分配给Boardroom
        uint256 treasuryReserve = Math.min(
            seigniorage.div(2),  // 只有50%的通胀
            IERC20(bond).totalSupply().sub(accumulatedSeigniorage)
        );
        // 如果 新增国库储备 > 0
        if (treasuryReserve > 0) {
            //累计GOC储备量 = 累计GOC储备量 + 新增国库储备量
            accumulatedSeigniorage = accumulatedSeigniorage.add(
                treasuryReserve
            );
            //触发已发放国库储备事件
            emit TreasuryFunded(now, treasuryReserve);
        }

        // shareBoardroom
        //董事会GOC新增储备量 = 新铸造的GOC - 新增国库储备量
        uint256 boardroomReserve = seigniorage.sub(treasuryReserve);
        if (boardroomReserve > 0) {
            // share董事会分到60%
            uint256 shareBoardroomReserve = boardroomReserve.mul(6).div(10);
            // lp董事会分到40%
            uint256 lpBoardroomReserve = boardroomReserve.sub(shareBoardroomReserve);
            // 批准国库合约储备量数额
            IERC20(cash).safeApprove(shareBoardroom, shareBoardroomReserve);
            //调用Boardroom合约的allocateSeigniorage方法,将GOC存入董事会
            IBoardroom(shareBoardroom).allocateSeigniorage(shareBoardroomReserve);

            // 批准国库合约储备量数额
            IERC20(cash).safeApprove(lpBoardroom, lpBoardroomReserve);
            //调用Boardroom合约的allocateSeigniorage方法,将GOC存入董事会
            IBoardroom(lpBoardroom).allocateSeigniorage(lpBoardroomReserve);
            //触发已发放资金至董事会事件
            emit BoardroomFunded(now, boardroomReserve);
        }
    }

    // GOV
    event Initialized(address indexed executor, uint256 at);
    event Migration(address indexed target);
    event ContributionPoolChanged(address indexed operator, address newFund);
    event ContributionPoolRateChanged(
        address indexed operator,
        uint256 newRate
    );
    event MaxInflationRateChanged(address indexed operator, uint256 newRate);
    event DebtAddRateChanged(address indexed operator, uint256 newRate);
    event MaxDebtRateChanged(address indexed operator, uint256 newRate);
    // CORE
    event RedeemedBonds(address indexed from, uint256 amount);
    event BoughtBonds(address indexed from, uint256 amount);
    event TreasuryFunded(uint256 timestamp, uint256 seigniorage);
    event BoardroomFunded(uint256 timestamp, uint256 seigniorage);
    event ContributionPoolFunded(uint256 timestamp, uint256 seigniorage);
    event SetOraclePriceOne(uint256 cashPriceOne);
    event BondReward(uint256 timestamp, uint256 seigniorage);
}
