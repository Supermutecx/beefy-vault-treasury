// SPDX-License-Identifier: MIT
pragma solidity ^0.8.17;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import "./interfaces/IBeefyVault.sol";
import "./interfaces/IUniswapRouter.sol";

contract Treasury is Ownable {
    using SafeERC20 for IERC20;

    struct VaultInfo {
        address vault;
        address want;
        uint256 allocation; 
        uint256 totalSupply;
    }

    VaultInfo[] public vaultInfos;
    address immutable stableCoin;
    uint256 public totalAllocation;


    // Events
    event Deposited(address _from, uint256 _amount);
    event VaultAdded(uint256 _index, address _vault, uint256 _allocation);
    event AllocationUpdated(uint256 _index, uint256 _newAllocation);

    constructor(address _stableCoin) {
        stableCoin = _stableCoin;
    }

    /**
     * @dev Deposit stable coin to the Treasury contract.
     * @param _amount The amount of stable coin to deposit.
     */
    function deposit(uint256 _amount) external {
        require(_amount > 0, "Treasury: Amount 0");

        IERC20(stableCoin).safeTransferFrom(_msgSender(), address(this), _amount);
        emit Deposited(_msgSender(), _amount);
    }

    /**
     * @dev Add a new vault to the Treasury contract.
     * @param _vault The address of the vault contract.
     * @param _allocation The allocation allocation of the vault.
     */
    function addVault(address _vault, uint256 _allocation) external onlyOwner {
        address _want = IBeefyVault(_vault).want();
        require(_want != address(0), "Treasury: Invalid wanted token");

        vaultInfos.push(VaultInfo(_vault, _want, _allocation, 0));
        totalAllocation += _allocation;

        emit VaultAdded(vaultInfos.length - 1, _vault, _allocation);
    }

    /**
     * @dev Update the allocation allocation of a vault.
     * @param _index The index of the vault to update.
     * @param _allocation The new allocation allocation.
     */
    function updateAllocation(
        uint256 _index,
        uint256 _allocation
    ) external onlyOwner {
        require(_index < vaultInfos.length, "Treasury: Invalid vault");

        VaultInfo storage vaultInfo = vaultInfos[_index];
        totalAllocation -= vaultInfo.allocation;

        vaultInfo.allocation = _allocation;
        totalAllocation += _allocation;

        emit AllocationUpdated(_index, _allocation);
    }

    /**
     * @dev Deposit funds across all vaults according to their allocation allocations.
     * @param _amount The amount of funds to deposit.
     */
    function depositToVault(uint256 _amount) external onlyOwner {
        require(_amount > 0, "Treasury: Amount 0");
        require(totalAllocation > 0, "Treasury: No Vault");

        for (uint256 i = 0; i < vaultInfos.length; i++) {
            VaultInfo memory vaultInfo = vaultInfos[i];

            if (vaultInfo.allocation > 0) {
                uint256 depositAmount = (_amount * vaultInfo.allocation) / totalAllocation;

                if (vaultInfo.want != stableCoin) {
                    IBeefyStrategy _strategy = IBeefyVault(vaultInfo.vault).strategy();
                    _addLiquidity(_strategy.unirouter(), _strategy.lpToken0(), _strategy.lpToken1(), _strategy.outputToLp0(), _strategy.outputToLp1());
                    depositAmount = IERC20(vaultInfo.want).balanceOf(address(this));
                }

                IERC20(stableCoin).safeApprove(vaultInfo.vault, depositAmount);
                IBeefyVault(vaultInfo.vault).deposit(depositAmount);

                vaultInfo.totalSupply += depositAmount;
            }
        }
    }

    /**
     * @dev Withdraw funds from a specific vault.
     * @param _index The index of the vault to withdraw from.
     * @param _shares The number of shares to withdraw.
     */
    function withdrawFromVault(uint256 _index, uint256 _shares) external onlyOwner {
        VaultInfo memory vaultInfo = vaultInfos[_index];

        IBeefyVault beefyVault = IBeefyVault(vaultInfo.vault);
        beefyVault.withdraw(_shares);

        if (vaultInfo.want != stableCoin) {
            IBeefyStrategy _strategy = IBeefyVault(vaultInfo.vault).strategy();
            address uniRouter = _strategy.unirouter();
            address token0 = _strategy.lpToken0();
            address token1 = _strategy.lpToken1();

            (uint256 amount0, uint256 amount1) = _removeLiquidity(uniRouter, _strategy.want(), token0, token1);

            if (token0 != stableCoin) {
                IERC20(token0).safeApprove(uniRouter, amount0);
                IUniswapRouter(uniRouter).swapExactTokensForTokens(amount0, 0, _reversePath(_strategy.outputToLp0()), address(this), block.timestamp);
            }

            if (token1 != stableCoin) {
                IERC20(token1).safeApprove(uniRouter, amount1);
                IUniswapRouter(uniRouter).swapExactTokensForTokens(amount1, 0, _reversePath(_strategy.outputToLp1()), address(this), block.timestamp);
            }
        }
    }

    /**
     * @dev Calculate the aggregate yield for a specific vault.
     * @param _index The index of the vault to calculate the yield for.
     * @return The aggregate yield percentage with 1000 MULTIPLIER
     */
    function calculateAggregateYield(uint256 _index) external view returns (uint256) {
        VaultInfo memory vaultInfo = vaultInfos[_index];
        IBeefyVault beefyVault = IBeefyVault(vaultInfo.vault);

        uint256 totalValueLocked = (beefyVault.balanceOf(address(this)) * beefyVault.getPricePerFullShare()) / 1e18;

        // Calculate the aggregate yield percentage with 1000 MULTIPLIER
        return ((totalValueLocked - vaultInfo.totalSupply) * 1e5) / vaultInfo.totalSupply;
    }

    /**
     * @dev Add liquidity to a Uniswap pair.
     * @param _uniRouter The address of the Uniswap router.
     * @param _token0 The address of the first token in the pair.
     * @param _token1 The address of the second token in the pair.
     * @param _outputToLp0Route The Uniswap route for swapping output token to LP token0.
     * @param _outputToLp1Route The Uniswap route for swapping output token to LP token1.
     */
    function _addLiquidity(address _uniRouter, address _token0, address _token1, address[] memory _outputToLp0Route, address[] memory _outputToLp1Route) internal {
        uint256 outputHalf = IERC20(stableCoin).balanceOf(address(this)) / 2;
        IERC20(stableCoin).safeApprove(_uniRouter, outputHalf);

        if (_token0 != stableCoin) {
            IUniswapRouter(_uniRouter).swapExactTokensForTokens(outputHalf, 0, _outputToLp0Route, address(this), block.timestamp);
        }

        if (_token1 != stableCoin) {
            IUniswapRouter(_uniRouter).swapExactTokensForTokens(outputHalf, 0, _outputToLp1Route, address(this), block.timestamp);
        }

        uint256 token0Amount = IERC20(_token0).balanceOf(address(this));
        uint256 token1Amount = IERC20(_token1).balanceOf(address(this));
        IERC20(_token0).safeApprove(_uniRouter, token0Amount);
        IERC20(_token1).safeApprove(_uniRouter, token1Amount);

        IUniswapRouter(_uniRouter).addLiquidity(_token0, _token1, token0Amount, token1Amount, 0, 0, address(this), block.timestamp);
    }

    /**
     * @dev Remove liquidity from a Uniswap pair.
     * @param _uniRouter The address of the Uniswap router.
     * @param _pair The address of the Uniswap pair.
     * @param _token0 The address of LP token0.
     * @param _token1 The address of LP token1.
     * @return amount0 token0 amount received from removing liquidity.
     * @return amount1 token1 amount received from removing liquidity.
     */
    function _removeLiquidity(address _uniRouter, address _pair, address _token0, address _token1) internal returns (uint256 amount0, uint256 amount1) {
        uint256 liquidity = IERC20(_pair).balanceOf(address(this));
        IERC20(_pair).safeApprove(_uniRouter, liquidity);

        (amount0, amount1) = IUniswapRouter(_uniRouter).removeLiquidity(_token0, _token1, liquidity, 0, 0, address(this), block.timestamp);
    }

    /**
     * @dev Reverse the order of addresses in a path.
     * @param _path The path of addresses.
     * @return The reversed path of addresses.
     */
    function _reversePath(address[] memory _path) internal pure returns (address[] memory) {
        address[] memory path = new address[](_path.length);
        uint256 index = _path.length - 1;
        for (uint256 i = 0; i <= index; i++) {
            path[i] = _path[index - i];
        }
        return path;
    }

    /**
     * @dev Withdraw funds from a specific vault.
     * @param _token The token address for withdrawing
     * @param _amount The amount of token to withdraw.
     */
    function withdrawERC20(address _token, uint256 _amount) external onlyOwner {
        require(IERC20(_token).balanceOf(address(this)) >= _amount, "Treasury: Insufficient Amount");
        IERC20(_token).safeTransfer(_msgSender(), _amount);
    }

}
