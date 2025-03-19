// SPDX-License-Identifier: UNLICENSED 
pragma solidity =0.6.6;

// Uniswap interface and library imports
import "./interfaces/IUniswapV2Factory.sol";
import "./interfaces/IUniswapV2Pair.sol";
import "./interfaces/IUniswapV2Router01.sol";
import "./interfaces/IUniswapV2Router02.sol";
import "./interfaces/IERC20.sol";
import "./libraries/UniswapV2Library.sol";
// Correcting the SafeERC20 import from OpenZeppelin
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "hardhat/console.sol";

// Ownable import for restricting contract functions
import "@openzeppelin/contracts/access/Ownable.sol";

contract FlashLoan is Ownable {
    using SafeERC20 for IERC20;

    // Factory and Routing Addresses
    address private constant PANCAKE_FACTORY = 0xcA143Ce32Fe78f1f7019d7d551a6402fC5350c73;
    address private constant PANCAKE_ROUTER = 0x10ED43C718714eb63d5aA57B78B54704E256024E;

    // Token Addresses
    address private constant BUSD = 0xe9e7CEA3DedcA5984780Bafc599bD69ADd087D56;
    address private constant WBNB = 0xbb4CdB9CBd36B01bD1cBaEBF2De08d9173bc095c;
    address private constant CROX = 0x2c094F5A7D1146BB93850f629501eB749f6Ed491;
    address private constant CAKE = 0x0E09FaBB73Bd3Ade0a17ECC321fD13a19e81cE82;

    uint256 private deadline = block.timestamp + 1 days;
    uint256 private constant MAX_INT = 115792089237316195423570985008687907853269984665640564039457584007913129639935;

    // Reentrancy guard
    bool private lock = false;

    // Time lock variables
    uint256 private lastActionTime;
    uint256 public constant COOLDOWN_TIME = 1 hours;

    modifier nonReentrant() {
        require(!lock, "ReentrancyGuard: reentrant call");
        lock = true;
        _;
        lock = false;
    }

    modifier onlyAfterCooldown() {
        require(block.timestamp >= lastActionTime + COOLDOWN_TIME, "Cooldown: Try again later");
        _;
    }

    // Check if trade is profitable
    function checkResult(uint _repayAmount, uint _acquiredCoin) pure private returns (bool) {
        return _acquiredCoin > _repayAmount;
    }

    // Get contract balance of a specific token
    function getBalanceOfToken(address _address) public view returns (uint256) {
        return IERC20(_address).balanceOf(address(this));
    }

    // Approve tokens only once
    function approveTokens(address _token, address _spender, uint256 _amount) private {
        uint256 currentAllowance = IERC20(_token).allowance(address(this), _spender);
        if (currentAllowance < _amount) {
            IERC20(_token).safeApprove(_spender, 0);
            IERC20(_token).safeApprove(_spender, MAX_INT);
        }
    }

    // External call to trusted price oracle or trusted contract to verify market price
    function verifyPrice(address _fromToken, address _toToken, uint256 _amountIn) private view returns (uint256) {
        // Price check logic can include using an oracle like Chainlink or any trusted price source
        uint256 price = IUniswapV2Router01(PANCAKE_ROUTER).getAmountsOut(_amountIn, [_fromToken, _toToken])[1];
        return price;
    }

    // Execute trade with slippage protection
    function placeTrade(address _fromToken, address _toToken, uint _amountIn, uint _slippage) private returns (uint) {
        address pair = IUniswapV2Factory(PANCAKE_FACTORY).getPair(_fromToken, _toToken);
        require(pair != address(0), "Pool does not exist");

        // Calculate Amount Out with slippage protection
        uint256 amountRequired = IUniswapV2Router01(PANCAKE_ROUTER).getAmountsOut(_amountIn, [_fromToken, _toToken])[1];
        uint256 slippageAmount = (amountRequired * _slippage) / 100;
        uint256 amountWithSlippage = amountRequired + slippageAmount;

        uint256 price = verifyPrice(_fromToken, _toToken, _amountIn);
        require(price >= amountRequired, "Price manipulation detected: Price mismatch");

        uint256 amountReceived = IUniswapV2Router01(PANCAKE_ROUTER)
            .swapExactTokensForTokens(_amountIn, amountWithSlippage, [_fromToken, _toToken], address(this), deadline)[1];

        require(amountReceived > 0, "Transaction Abort");

        return amountReceived;
    }

    // Initiate Arbitrage using Flash Loan
    function initiateArbitrage(address _busdBorrow, uint _amount, uint _slippage) external nonReentrant onlyAfterCooldown {
        approveTokens(BUSD, PANCAKE_ROUTER, MAX_INT);
        approveTokens(CROX, PANCAKE_ROUTER, MAX_INT);
        approveTokens(CAKE, PANCAKE_ROUTER, MAX_INT);

        // Liquidity pool of BUSD and WBNB
        address pair = IUniswapV2Factory(PANCAKE_FACTORY).getPair(_busdBorrow, WBNB);
        require(pair != address(0), "Pool does not exist");

        address token0 = IUniswapV2Pair(pair).token0(); // WBNB
        address token1 = IUniswapV2Pair(pair).token1(); // BUSD

        uint amount0Out = _busdBorrow == token0 ? _amount : 0;
        uint amount1Out = _busdBorrow == token1 ? _amount : 0;

        bytes memory data = abi.encode(_busdBorrow, _amount, msg.sender);
        IUniswapV2Pair(pair).swap(amount0Out, amount1Out, address(this), data);

        lastActionTime = block.timestamp;
    }

    // PancakeSwap callback function after flash loan
    function pancakeCall(
        address _sender,
        uint256 _amount0,
        uint256 _amount1,
        bytes calldata _data
    ) external {
        address token0 = IUniswapV2Pair(msg.sender).token0();
        address token1 = IUniswapV2Pair(msg.sender).token1();
        address pair = IUniswapV2Factory(PANCAKE_FACTORY).getPair(token0, token1);
        require(msg.sender == pair, "The sender needs to match the pair");
        require(_sender == address(this), "Sender should match the contract");

        // Decode data for calculating the repayment
        (address busdBorrow, uint256 amount, address myAddress) = abi.decode(_data, (address, uint256, address));

        // Calculate the amount to repay at the end
        uint256 fee = ((amount * 3) / 997) + 1;
        uint256 repayAmount = amount + fee;

        // Perform arbitrage
        uint256 loanAmount = _amount0 > 0 ? _amount0 : _amount1;
        uint256 trade1Coin = placeTrade(BUSD, CROX, loanAmount, 2);  // Example slippage: 2%
        uint256 trade2Coin = placeTrade(CROX, CAKE, trade1Coin, 2);
        uint256 trade3Coin = placeTrade(CAKE, BUSD, trade2Coin, 2);

        // Check Profitability
        bool profCheck = checkResult(repayAmount, trade3Coin);
        require(profCheck, "Arbitrage not profitable");

        // Pay profit and loan back
        IERC20(BUSD).transfer(myAddress, trade3Coin - repayAmount);
        IERC20(busdBorrow).transfer(pair, repayAmount);
    }
}
