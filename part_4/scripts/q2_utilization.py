import psutil
import time

print('Time,C0,C1,C2,C3')

while True:
    print('{},{}'.format(int(time.time() * 1000), ','.join(str(core)
          for core in psutil.cpu_percent(0.1, percpu=True))))
