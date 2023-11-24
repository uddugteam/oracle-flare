package flare

import (
	"fmt"

	"github.com/ethereum/go-ethereum/ethclient"

	"oracle-flare/config"
	"oracle-flare/pkg/flare/contracts"
	"oracle-flare/pkg/flare/contracts/flareChain"
	"oracle-flare/pkg/flare/contracts/songbirdChain"
)

type IFlare interface {
	Close()
}

type flare struct {
	priceSubmitter contracts.IPriceSubmitter
	register       *registerContract
	conf           *config.Flare
	provider       *ethclient.Client
}

func NewFlare(conf *config.Flare) IFlare {
	f := &flare{
		conf: conf,
	}

	f.init()

	return f
}

func (f *flare) init() {
	id := ChainIDFromInt(f.conf.ChainID)

	if id == UnknownChain {
		logFatal(fmt.Sprintf("chain id: %v not supported", f.conf.ChainID), "Init")
	}

	if f.conf.RpcURL == "" {
		logFatal("no rpc provider url found in the config", "Init")
	}

	rpc, err := ethclient.Dial(f.conf.RpcURL)
	if err != nil {
		logFatal(fmt.Sprintf("err dial provider %s: %s", f.conf.RpcURL, err.Error()), "Init")
	}

	f.provider = rpc

	if f.conf.RegistryContractAddress == "" {
		logFatal("no registry priceSubmitter found in the config", "Init")
	}

	f.register = newRegisterContract(f.provider, f.conf.RegistryContractAddress)

	submitterAddress, err := f.register.getContractAddress("PriceSubmitter")
	if err != nil {
		logFatal(fmt.Sprintln("get submitter address error:", err.Error()), "Init")
	}

	switch id {
	case FlareChain:
		f.priceSubmitter = flareChain.NewPriceSubmitter(f.provider, *submitterAddress)
	case SongBirdChain:
		f.priceSubmitter = songbirdChain.NewPriceSubmitter(f.provider, *submitterAddress)
	}
}

func (f *flare) Close() {
	logInfo("close rpc provider connection...", "Close")
	if f.provider != nil {
		f.provider.Close()
	}
}
