import numpy as np
import os
import time
import argparse
from datetime import datetime


def parse_scheduler_log(logfile, start_ts):
    # Ensure time is GMT
    os.environ['TZ'] = 'GMT'
    time.tzset()

    # Read in the scheduler log
    with open(logfile) as logfile:
        log = logfile.readlines()

    # Parse a list of time pairs for each job
    bm_intervals = {}
    bm_open = {}
    end_time = 0

    for line in log:
        line = line[:-1]
        # Split timestamp and event
        datestr = line[:19]
        event_desc = line[20:]

        # Get the POSIX timestamp
        ts = int(datetime.strptime(datestr, '%Y/%m/%d %H:%M:%S').timestamp())
        rel_time = int(ts - (start_ts / 1000.))
        end_time = max(end_time, rel_time)

        if event_desc.startswith('Started job '):
            # Benchmark starting, open interval
            bm_open[event_desc[len('Started job '):]] = rel_time

        elif event_desc.startswith('Unpaused job '):
            # Benchmark unpausing, open interval
            bm_open[event_desc[len('Unpaused job '):]] = rel_time

        elif event_desc.startswith('Completed job ') or event_desc.startswith('Paused job '):
            prefix = 'Completed job ' if event_desc.startswith(
                'Completed job ') else 'Paused job '

            # Benchmark ending or pausing, close and append interval
            job_name = event_desc[len(prefix):]

            if job_name not in bm_intervals:
                bm_intervals[job_name] = []

            bm_intervals[job_name].append(
                (bm_open[job_name], rel_time - bm_open[job_name]))

    return end_time, bm_intervals


def extract_times(rep_dir):
    # Get the start timestamp from the raw latency file
    start_ts = None

    with open(os.path.join(rep_dir, 'latencies.raw')) as latfile:
        for line in latfile:

            if line.startswith('Timestamp start: '):
                start_ts = int(line[len('Timestamp start: '):])

    # Parse scheduler log
    end_time, bm_intervals = parse_scheduler_log(
        os.path.join(rep_dir, 'scheduler.log'), start_ts)

    times = {}

    # Preset benchmark order to maintain same order as table
    for job in ['dedup', 'blackscholes', 'ferret', 'freqmine', 'canneal', 'splash2x-fft']:
        job_time = 0

        for interval in bm_intervals[job]:
            job_time += interval[1]

        times[job] = job_time

    times['total time'] = end_time
    return times


def main(rep_dirs, outfile):
    times = {}

    # Get times from all rep dirs
    for rep_dir in rep_dirs:
        rep_times = extract_times(rep_dir)

        for job, time in rep_times.items():
            if job not in times:
                times[job] = []

            times[job].append(time)

    # Write output in latex table format
    with open(outfile, 'w') as f:
        f.write('\\begin{table}[h]\n')
        f.write('\\centering\n')
        f.write('\t\\begin{tabular}{ |c|c|c|c|c|}\n')
        f.write('\t\\hline\n')
        f.write('\tjob name & mean time [s] & std [s] \\\\\n')
        f.write('\t\\hhline{ |= |= |= |}\n')

        for job, time in times.items():
            if job == 'splash2x-fft':
                job = 'fft'

            f.write('\t{} & {:.2f} & {:.2f} \\\\  \\hline\n'.format(
                job, np.mean(time), np.std(time)))

        f.write('\t\\end{tabular}\n')
        f.write('\\end{table}\n')


# \begin{table}[h]
# \centering
#     \begin{tabular}{| c|c|c|c|c|}
#     \hline
#     job name & mean time[s] & std[s] \\
#     \hhline{ |= |= |= |}
#     dedup & & \\  \hline
#     blackscholes & & \\  \hline
#     ferret & & \\  \hline
#     freqmine & & \\  \hline
#     canneal & & \\  \hline
#     fft & & \\  \hline
#     total time & & \\ \hline
#     \end{tabular}
# \end{table}

if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('--rep1', help='Result dir of repetition 1.',
                        required=True)
    parser.add_argument('--rep2', help='Result dir of repetition 2.',
                        required=True)
    parser.add_argument('--rep3', help='Result dir of repetition 3.',
                        required=True)
    parser.add_argument('--outfile', help='Output path for file (plaintext)',
                        required=True)
    args = parser.parse_args()
    main([args.rep1, args.rep2, args.rep3], args.outfile)
