from pathlib import Path

import pandas as pd
import matplotlib.pyplot as plt
import seaborn as sns
import argparse
import os

line_opts = {
    'capsize': 3, 'capthick': 1, 'elinewidth': 1.2,
    'linewidth': 1, 'markersize': 6
}

def generate_plot(latencies_df, results_dir):
    result = latencies_df.groupby(['T', 'C', 'target'], as_index=False).agg(
                {'p95': ['mean', 'std'], 'QPS': ['mean', 'std']} )

    sns.set(style='darkgrid', font_scale=1.4)
    sns.set_palette(sns.color_palette('bright'))

    fig, axes = plt.subplots(figsize=(14,10))
    axes.xaxis.set_tick_params(labelsize='small')
    axes.yaxis.set_tick_params(labelsize='small')

    # titles
    plt.title('Memcached Performance')
    plt.ylabel('Mean p95 latency (µs)')
    plt.xlabel('Mean QPS (#queries / sec)')

    # specify limits
    plt.xticks(range(0, 120001, 10000))
    axes.set_xlim([0, 125000])

    for comb, df in result.groupby(['T','C']):
        axes.errorbar(x=df[('QPS', 'mean')], xerr=df[('QPS', 'std')],
                      y=df[('p95', 'mean')], yerr=df[('p95', 'std')],
                      label='T = {}, C = {}'.format(comb[0], comb[1]),
                      **line_opts)
    axes.legend()
    output_f = os.path.join(Path(results_dir), 'perf_plot.pdf')
    plt.savefig(output_f, pad_inches=0, bbox_inches='tight')


def main(results_dir, input_csv):
    latencies_df = pd.read_csv(input_csv)
    generate_plot(latencies_df, results_dir)


if __name__=='__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('--output', help='output directory to store results',
                        required=True)
    parser.add_argument('--input-csv', help='CSV file with memcached latencies',
                        required=True)
    args = parser.parse_args()
    main(args.output, args.input_csv)

