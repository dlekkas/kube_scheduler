import pandas as pd
import matplotlib.pyplot as plt

from pathlib import Path
from tabulate import tabulate
import argparse
import os
import sys


latencies_f = 'memcached_latencies.dat'
job_times_f = 'job_results.csv'

def main(results_dir, n_reps):
    output_f = os.path.join(Path(results_dir), 'question_3_2_1.txt')
    all_files = Path(results_dir).rglob(job_times_f)

    df = pd.concat((pd.read_csv(f) for f in all_files))
    res_df = df[['job','total_time']].groupby('job').mean().reset_index()
    result = df[['job','total_time']].groupby(['job'], as_index=False).agg(
            {'total_time': ['mean','std']})

    # generate the table required by question 3.2.1 of the report and store
    # it in file 'question_3_2_1.txt'
    print(tabulate(result, headers='keys', tablefmt = 'psql'),
            file=open(output_f, 'w'))

    for i in range(1, n_reps+1):
        curr_res_dir = Path(os.path.join(Path(results_dir), 'rep_{}'.format(i)))
        figure, axes = plt.subplots(nrows=2, ncols=1, sharex=True)
        figure.suptitle('Repetition #{}'.format(i))

        curr_lat_f = os.path.join(Path(curr_res_dir), latencies_f)
        latencies_df = pd.read_csv(curr_lat_f, delim_whitespace=True)

        curr_job_f = os.path.join(Path(curr_res_dir), job_times_f)
        jobs_df = pd.read_csv(curr_job_f)


        latencies_df['time'] = pd.Series(
                20*i for i in range(1,len(latencies_df)+1))

        latencies_df.plot(x='time', y='p95', kind='line', marker='o', ax=axes[0])
        axes[0].set_ylabel('p95 latency [ms]')

        # Generate barh schedule graph
        for j, row in jobs_df.iterrows():
            job_time_pair = (row['start_time'], row['start_time'] + row['total_time'])
            axes[1].broken_barh([job_time_pair], (10*(j+1),9), facecolors='cyan')
        axes[1].set_yticks([15 + 10*j for j in range(len(jobs_df))])
        axes[1].set_yticklabels(list(jobs_df['job']))
        axes[1].set_ylim(5, 15 + 10*len(jobs_df))
        axes[1].set_xlabel('Time [s]')

        plt.savefig(os.path.join(Path(curr_res_dir), 'slo_plot.png'))


if __name__=="__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument('--results-dir', help='directory with results', required=True)
    parser.add_argument('--n-reps', help='number of repetitions', type=int, required=True)
    args = parser.parse_args()
    main(args.results_dir, args.n_reps)

