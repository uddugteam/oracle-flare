package internal

import (
	"fmt"
	"oracle-flare/pkg/logger"
	"os"
	"os/signal"
	"syscall"

	version "github.com/misnaged/annales/versioner"

	"oracle-flare/config"
)

// App is main microservice application instance that
// have all necessary dependencies inside structure
type App struct {
	// application configuration
	config *config.Scheme

	version *version.Version
}

// NewApplication create new App instance
func NewApplication() (app *App, err error) {
	ver, err := version.NewVersion()
	if err != nil {
		return nil, fmt.Errorf("init app version: %w", err)
	}

	return &App{
		config:  &config.Scheme{},
		version: ver,
	}, nil
}

// Init initialize application and all necessary instances
func (app *App) Init() error {
	return nil
}

// Serve start serving Application service
func (app *App) Serve() error {

	// Gracefully shutdown the server
	quit := make(chan os.Signal, 1)
	signal.Notify(quit, syscall.SIGINT, syscall.SIGTERM, syscall.SIGQUIT)

	<-quit

	return nil
}

// Stop shutdown the application
func (app *App) Stop() {
	logger.Log().WithField("layer", "App").Info("app stop...")
}

// Config return App config Scheme
func (app *App) Config() *config.Scheme {
	return app.config
}

// Version return application current version
func (app *App) Version() string {
	return app.version.String()
}

// CreateAddr is create address string from host and port
func CreateAddr(host string, port int) string {
	return fmt.Sprintf("%s:%v", host, port)
}
