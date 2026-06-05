package main

import (
	"fmt"
	"log"
	"os"
)

func diffManifests(sourcePath string, destPath string, outputPath string) error {
	sourceRecords, err := readBlockManifest(sourcePath)
	if err != nil {
		return err
	}
	destRecords, err := readBlockManifest(destPath)
	if err != nil {
		return err
	}

	sourceByIndex := make(map[uint64]BlockRecord, len(sourceRecords))
	for _, rec := range sourceRecords {
		sourceByIndex[rec.Index] = rec
	}
	destByIndex := make(map[uint64]BlockRecord, len(destRecords))
	for _, rec := range destRecords {
		destByIndex[rec.Index] = rec
	}

	out, err := os.Create(outputPath)
	if err != nil {
		return fmt.Errorf("create diff list %s: %w", outputPath, err)
	}
	defer out.Close()

	var mismatched uint64
	var missingOnDest uint64
	var missingOnSource uint64

	allIndexes := make(map[uint64]struct{})
	for index := range sourceByIndex {
		allIndexes[index] = struct{}{}
	}
	for index := range destByIndex {
		allIndexes[index] = struct{}{}
	}

	for index := range allIndexes {
		sourceRec, sourceOK := sourceByIndex[index]
		destRec, destOK := destByIndex[index]

		switch {
		case sourceOK && destOK && sourceRec.MD5 == destRec.MD5:
			continue
		case !sourceOK:
			missingOnSource++
			rec := DiffRecord{
				Index:  index,
				Offset: destRec.Offset,
				Size:   destRec.Size,
				Reason: "missing_on_source",
				Dest:   destRec.MD5,
			}
			if err := writeDiffRecord(out, rec); err != nil {
				return err
			}
		case !destOK:
			missingOnDest++
			rec := DiffRecord{
				Index:  index,
				Offset: sourceRec.Offset,
				Size:   sourceRec.Size,
				Reason: "missing_on_dest",
				Source: sourceRec.MD5,
			}
			if err := writeDiffRecord(out, rec); err != nil {
				return err
			}
		default:
			mismatched++
			rec := DiffRecord{
				Index:  index,
				Offset: sourceRec.Offset,
				Size:   sourceRec.Size,
				Reason: "hash_mismatch",
				Source: sourceRec.MD5,
				Dest:   destRec.MD5,
			}
			if err := writeDiffRecord(out, rec); err != nil {
				return err
			}
		}
	}

	log.Printf("diff complete: %d hash mismatches, %d missing on dest, %d missing on source", mismatched, missingOnDest, missingOnSource)
	log.Printf("wrote %s", outputPath)
	return nil
}
