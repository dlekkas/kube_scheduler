#!/bin/bash
#######################################
# Post processing of PARSEC timeing output.
# Convert time unit from minutes to seconds.
# Arguments:
#   The raw log from a PARSEC job.
#   The csv file to append to.
#######################################
function post_processing() {
  egrep '.*\s\d+m' $1 \
    | awk '{print $2}' \
    | sed -E 's/^(.*)m(.*)s$/\1 \2/' \
    | awk '{print $1 * 60 + $2}' \
    | paste -sd "," - \
    >>$2
}

header='real,user,sys'

results_dir=../results/part2a
for fib in $results_dir/*; do
  for fps in $fib/*; do
    fm=$fps/measurements.csv
    echo $header >$fm
    for i in {1..5}; do
      post_processing $fps/raw.$i $fm
    done
  done
done

results_dir=../results/part2b
for fps in $results_dir/*; do
  for ft in $fps/*; do
    fm=$ft/measurements.csv
    echo $header >$fm
    for i in {1..5}; do
      post_processing $ft/raw.$i $fm
    done
  done
done
