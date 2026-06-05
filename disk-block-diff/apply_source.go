package main

import (
	"fmt"
	"io"
	"os"
)

type applySource struct {
	reader io.ReaderAt
	close  func() error
	label  string
}

func openApplySource(sourcePath string, nbdStatePath string) (*applySource, error) {
	if nbdStatePath != "" {
		return openApplySourceFromNbdState(nbdStatePath)
	}
	if sourcePath == "" {
		return nil, fmt.Errorf("source device path is required")
	}
	file, err := os.Open(sourcePath)
	if err != nil {
		return nil, err
	}
	return &applySource{
		reader: file,
		close:  file.Close,
		label:  sourcePath,
	}, nil
}

func openApplySourceFromNbdState(statePath string) (*applySource, error) {
	if statePath == "" {
		statePath = defaultNbdState
	}
	state, err := readNbdSessionState(statePath)
	if err != nil {
		return nil, err
	}
	if state == nil {
		return nil, fmt.Errorf("no NBD session state at %s", statePath)
	}
	if state.Device != "" {
		file, err := os.Open(state.Device)
		if err != nil {
			return nil, err
		}
		return &applySource{
			reader: file,
			close:  file.Close,
			label:  state.Device,
		}, nil
	}
	if state.Socket != "" {
		reader, closeFn, err := openLibnbdSocket(state.Socket)
		if err != nil {
			return nil, err
		}
		return &applySource{
			reader: reader,
			close:  closeFn,
			label:  "nbd+unix://" + state.Socket,
		}, nil
	}
	return nil, fmt.Errorf("no NBD source device or socket in %s", statePath)
}
