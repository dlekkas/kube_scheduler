import json
import sys
from datetime import datetime

file = open(sys.argv[1], 'r')
json_file = json.load(file)

time_format = '%Y-%m-%dT%H:%M:%SZ'

# We take as reference the start time of the memcached and we are going
# to calculate relative start times in order to plot the graphs of q3.1
ref_time = datetime.strptime(sys.argv[2], time_format)

start_times = []
completion_times = []
print("job,start_time,total_time")
for item in json_file['items']:
    name = str(item['metadata']['name']).split('-')[1]
    start_time = datetime.strptime(item['status']['startTime'], time_format)
    completion_time = datetime.strptime(item['status']['completionTime'],
                                        time_format)
    job_time = (completion_time - start_time).total_seconds()
    relative_start_time = (start_time - ref_time).total_seconds()
    print('{},{},{}'.format(name, int(relative_start_time), int(job_time)))

    start_times.append(start_time)
    completion_times.append(completion_time)
    if not item['status']['succeeded']:
        print("Job {0} has not terminated!".format(name))

if len(start_times) != 6 and len(completion_times) != 6:
    print("You haven't run all the PARSEC jobs. Exiting...")
    sys.exit(0)

file.close()
