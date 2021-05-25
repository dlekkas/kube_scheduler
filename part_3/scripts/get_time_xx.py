import json
import sys
from datetime import datetime


time_format = '%Y-%m-%dT%H:%M:%SZ'
file = open(sys.argv[1], 'r')
json_file = json.load(file)

# We take as reference the start time of the memcached and we are going
# to calculate relative start times in order to plot the graphs of q3.1
ref_time = datetime.strptime(sys.argv[2], time_format)

start_times = []
completion_times = []
print("job,start_time,total_time")
for item in json_file['items']:
    if 'job-name' not in item['metadata']['labels']:
        continue
    name = str(item['metadata']['labels']['job-name'].split('-')[1])
    try:
        start_time = datetime.strptime(
                item['status']['containerStatuses'][0]['state']['terminated']['startedAt'],
                time_format)
        completion_time = datetime.strptime(
                item['status']['containerStatuses'][0]['state']['terminated']['finishedAt'],
                time_format)

        job_time = (completion_time - start_time).total_seconds()
        relative_start_time = (start_time - ref_time).total_seconds()
        print('{},{},{}'.format(name, int(relative_start_time), int(job_time)))

        start_times.append(start_time)
        completion_times.append(completion_time)
    except KeyError:
        print("Job {0} has not completed....".format(name))
        sys.exit(0)

if len(start_times) != 6 and len(completion_times) != 6:
    print("You haven't run all the PARSEC jobs. Exiting...")
    sys.exit(0)

file.close()

