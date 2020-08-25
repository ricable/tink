package main

import (
	"context"
	"crypto/tls"
	"fmt"
	"io/ioutil"
	"os"
	"os/signal"
	"strings"
	"syscall"
	"time"

	"github.com/packethost/pkg/log"
	"github.com/spf13/cobra"
	"github.com/spf13/pflag"
	rpcServer "github.com/tinkerbell/tink/grpc-server"
	httpServer "github.com/tinkerbell/tink/http-server"
)

var (
	// version is set at build time
	version = "devel"

	rootCmd = &cobra.Command{
		Use:     "tink-server",
		Short:   "Tinkerbell provisioning and workflow engine",
		Long:    "Tinkerbell provisioning and workflow engine",
		Version: version,
		Run: func(cmd *cobra.Command, args []string) {
			log, cleanup, err := log.Init("github.com/tinkerbell/tink")
			if err != nil {
				panic(err)
			}
			defer cleanup()

			log.Info("starting version " + version)

			ctx, closer := context.WithCancel(context.Background())
			errCh := make(chan error, 2)

			facility, err := cmd.PersistentFlags().GetString("facility")
			if err != nil {
				log.Error(err)
				panic(err)
			}
			if facility == "" {
				facility = os.Getenv("FACILITY")
			}

			log = log.With("facility", facility)

			tlsCert, certPEM, modT := getCerts(cmd.PersistentFlags(), facility, log)
			rpcServer.SetupGRPC(ctx, log, facility, certPEM, tlsCert, modT, errCh)
			httpServer.SetupHTTP(ctx, log, certPEM, modT, errCh)

			sigs := make(chan os.Signal, 1)
			signal.Notify(sigs, syscall.SIGINT, syscall.SIGQUIT, syscall.SIGTERM)
			select {
			case err = <-errCh:
				log.Error(err)
				panic(err)
			case sig := <-sigs:
				log.With("signal", sig.String()).Info("signal received, stopping servers")
			}
			closer()

			// wait for grpc server to shutdown
			err = <-errCh
			if err != nil {
				log.Error(err)
				panic(err)
			}
			err = <-errCh
			if err != nil {
				log.Error(err)
				panic(err)
			}
		},
	}
)

func main() {
	rootCmd.PersistentFlags().String("ca-cert", "", "File containing the ca certificate")
	rootCmd.PersistentFlags().String("tls-cert", "bundle.pem", "File containing the tls certificate")
	rootCmd.PersistentFlags().String("tls-key", "server-key.pem", "File containing the tls private key")
	rootCmd.PersistentFlags().String("facility", "", "Facility")

	rootCmd.Execute()
}

func getCerts(flagSet *pflag.FlagSet, facility string, logger log.Logger) (tls.Certificate, []byte, time.Time) {
	var (
		modT         time.Time
		caCertBytes  []byte
		tlsCertBytes []byte
		tlsKeyBytes  []byte
	)

	caPath, err := flagSet.GetString("ca-cert")
	if err != nil {
		logger.Error(err)
		panic(err)
	}

	if caPath != "" {
		ca, modified, err := readFromFile(caPath)
		if err != nil {
			err = fmt.Errorf("failed to read ca cert: %w", err)
			logger.Error(err)
			panic(err)
		}
		if modified.After(modT) {
			modT = modified
		}
		caCertBytes = ca
	}

	certPath, err := flagSet.GetString("tls-cert")
	if err != nil {
		logger.Error(err)
		panic(err)
	}

	if certPath != "" {
		cert, modified, err := readFromFile(certPath)
		if err != nil {
			err = fmt.Errorf("failed to read tls cert: %w", err)
			logger.Error(err)
			panic(err)
		}
		if modified.After(modT) {
			modT = modified
		}
		tlsCertBytes = cert
	}

	keyPath, err := flagSet.GetString("tls-key")
	if err != nil {
		logger.Error(err)
		panic(err)
	}

	if keyPath != "" {
		key, modified, err := readFromFile(keyPath)
		if err != nil {
			err = fmt.Errorf("failed to read tls key: %w", err)
			logger.Error(err)
			panic(err)
		}
		if modified.After(modT) {
			modT = modified
		}
		tlsKeyBytes = key
	}

	// If we haven't read any certificates or keys, fallback to the previous lookup
	if len(caCertBytes) == 0 && len(tlsCertBytes) == 0 && len(tlsKeyBytes) == 0 {
		return fallbackCerts(facility, logger)
	}

	// Fail if we haven't read in a tls certificate
	if len(tlsCertBytes) == 0 {
		err := fmt.Errorf("--tls-cert is required")
		logger.Error(err)
		panic(err)
	}

	// Fail if we haven't read in a tls key
	if len(tlsKeyBytes) == 0 {
		err := fmt.Errorf("--tls-key is required")
		logger.Error(err)
		panic(err)
	}

	// If we read in a separate ca certificate, concatenate it with the tls cert
	if len(caCertBytes) > 0 {
		tlsCertBytes = append(caCertBytes, tlsCertBytes...)
	}

	cert, err := tls.X509KeyPair(tlsCertBytes, tlsKeyBytes)
	if err != nil {
		err = fmt.Errorf("failed to ingest TLS files: %w", err)
		logger.Error(err)
		panic(err)
	}
	return cert, tlsCertBytes, modT
}

func fallbackCerts(facility string, logger log.Logger) (tls.Certificate, []byte, time.Time) {
	var (
		certPEM []byte
		modT    time.Time
	)

	certsDir := os.Getenv("TINKERBELL_CERTS_DIR")
	if certsDir == "" {
		certsDir = "/certs/" + facility
	}
	if !strings.HasSuffix(certsDir, "/") {
		certsDir += "/"
	}

	certFile, err := os.Open(certsDir + "bundle.pem")
	if err != nil {
		err = fmt.Errorf("failed to open TLS cert: %w", err)
		logger.Error(err)
		panic(err)
	}

	if stat, err := certFile.Stat(); err != nil {
		err = fmt.Errorf("failed to stat TLS cert: %w", err)
		logger.Error(err)
		panic(err)
	} else {
		modT = stat.ModTime()
	}

	certPEM, err = ioutil.ReadAll(certFile)
	if err != nil {
		err = fmt.Errorf("failed to read TLS cert: %w", err)
		logger.Error(err)
		panic(err)
	}
	keyPEM, err := ioutil.ReadFile(certsDir + "server-key.pem")
	if err != nil {
		err = fmt.Errorf("failed to read TLS key: %w", err)
		logger.Error(err)
		panic(err)
	}

	cert, err := tls.X509KeyPair(certPEM, keyPEM)
	if err != nil {
		err = fmt.Errorf("failed to ingest TLS files: %w", err)
		logger.Error(err)
		panic(err)
	}
	return cert, certPEM, modT
}

func readFromFile(filePath string) ([]byte, time.Time, error) {
	var modified time.Time

	f, err := os.Open(filePath)
	if err != nil {
		return nil, modified, err
	}

	stat, err := f.Stat()
	if err != nil {
		return nil, modified, err
	}

	modified = stat.ModTime()

	contents, err := ioutil.ReadAll(f)
	if err != nil {
		return nil, modified, err
	}

	return contents, modified, nil
}
