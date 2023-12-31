package songbirdChain

import (
	"log"
	"math/big"

	"github.com/ethereum/go-ethereum/accounts/abi"
	"github.com/ethereum/go-ethereum/accounts/abi/bind"
	"github.com/ethereum/go-ethereum/common"
	"github.com/ethereum/go-ethereum/ethclient"

	songbird_abi "oracle-flare/abis/songbird"
	"oracle-flare/pkg/flare/contracts"
	"oracle-flare/pkg/logger"
	"oracle-flare/utils/contractUtils"
)

// priceSubmitter is a PriceSubmitter songbird-net smart-contract struct, implementing contracts.IPriceSubmitter interface
type priceSubmitter struct {
	address  common.Address
	abi      *abi.ABI
	contract *bind.BoundContract
	provider *ethclient.Client
}

// NewPriceSubmitter is used to get new priceSubmitter instance
func NewPriceSubmitter(provider *ethclient.Client, address common.Address) contracts.IPriceSubmitter {
	c := &priceSubmitter{
		provider: provider,
		address:  address,
	}

	c.init()

	return c
}

// init is used to create new smart-contract instance
func (c *priceSubmitter) init() {
	abiI, contract, err := contractUtils.GetContract(songbird_abi.IPriceSubmitter, c.address, c.provider, c.provider)
	if err != nil {
		logger.Log().WithField("layer", "PriceSubmitter-Init").Fatalln("err get contract:", err.Error())
	}

	c.abi = abiI
	c.contract = contract
}

// CommitPrices is used to hash and commit given data
func (c *priceSubmitter) CommitPrices(epochID *big.Int, indices []contracts.TokenID, prices []*big.Int, random *big.Int) error {
	//TODO: implement
	log.Printf("received commit epoch:%v random:%v price:%v", epochID.Uint64(), random.Uint64(), prices[0].Uint64())

	return nil
}

// RevealPrices is used to reveal given data
func (c *priceSubmitter) RevealPrices(epochID *big.Int, indices []contracts.TokenID, prices []*big.Int, random *big.Int) error {
	//TODO: implement
	log.Printf("received reveal epoch:%v random:%v price:%v", epochID.Uint64(), random.Uint64(), prices[0].Uint64())

	return nil
}
