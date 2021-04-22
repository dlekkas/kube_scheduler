import pandas as pd
import matplotlib.pyplot as plt
import matplotlib as mpl

import argparse
import subprocess
import datetime
import signal
import sys
import time

# Set the default color cycle
mpl.rcParams['axes.prop_cycle'] = mpl.cycler(color=["r", "k", "b"])

util_d = {'node': [], 'cpu': [], 'mem': [], 'time': []}

def plot_utilization():
    util_df = pd.DataFrame.from_dict(util_d)
    util_df.set_index('time', inplace=True)

    figure, axes = plt.subplots(nrows=2, ncols=1, sharex=True)
    util_df.groupby('node')['cpu'].plot(legend=True, ax=axes[0])
    util_df.groupby('node')['mem'].plot(legend=True, ax=axes[1])
    axes[0].set_ylabel("CPU utilization (%)")
    axes[0].set_ylim(0, 102)
    axes[1].set_ylabel("Memory utilization (%)")
    axes[1].set_ylim(0, 102)
    axes[1].set_xlabel("Time (sec)")

    figure.suptitle('Cluster utilization')
    plt.savefig('test_util.png')


def main(interval, nodes):

    def signal_handler(sig, frame):
        plot_utilization()
        sys.exit(0)

    signal.signal(signal.SIGINT, signal_handler)
    start_ts = datetime.datetime.now()
    while True:
        grep_match_regex = " '{}' ".format('|'.join(nodes))
        result = subprocess.run(['bash', '-c', "kubectl top node | grep -E" +
                                 grep_match_regex + "| awk '{print $1,$3,$5}'"],
                                 stdout=subprocess.PIPE)
        curr_ts = (datetime.datetime.now() - start_ts).total_seconds()
        f_output = result.stdout.decode('utf-8').replace('%','')
        for line in f_output.split('\n')[:-1]:
            try:
                util_d['node'].append(str(line.split()[0]))
                util_d['cpu'].append(int(line.split()[1]))
                util_d['mem'].append(int(line.split()[2]))
                util_d['time'].append(curr_ts)
            except:
                print('Error while parsing metrics from metrics-server')

        time.sleep(interval)


def check_node_validity(value):
    valid_nodes = ['node-a-2core', 'node-b-4core', 'node-c-8core']
    if value not in valid_nodes:
        raise argparse.ArgumentTypeError(
                "{} is an invalid cca-project-nodetype label.".format(value))
    return value

if __name__=="__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument('--interval', help='interval (sec) to monitor CPU/MEM',
                        required=False, default=3)
    parser.add_argument('--nodes', help='cca-project-nodetype labels',
                        nargs='+', type=check_node_validity,
                        default=['node-a-2core', 'node-b-4core', 'node-c-8core'])
    args = parser.parse_args()
    main(args.interval, args.nodes)

