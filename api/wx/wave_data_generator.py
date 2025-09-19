import io, os, csv, random, math, cmath, pytz
import numpy as np
import pandas as pd
from datetime import datetime, timedelta
from wx.models import FTPServer
from ftplib import FTP, error_perm, error_reply

from tempestas_api import settings
from celery import shared_task
from celery.utils.log import get_task_logger

MEASUREMENT_PERIOD = 1 # 1 Second
MEASUREMENT_WINDOW = 900 # 15 minutes

logger = get_task_logger(__name__)
db_logger = get_task_logger('db')

class wave(): # Wave object
    def __init__(self, frequency: float, phase_rad: float, height: float):
        self.height = height # Wave height in m
        self.frequence = frequency # Frequency in Hz
        self.phase_rad = phase_rad # Phase is radians
        self.time = None
        self.wave = None

    def gen_sinewave(self, time):
        self.time = time
        self.wave = self.height*np.sin(self.frequence*2*np.pi*time+self.phase_rad)
        return self.wave

def gen_random_wave():
    frequency = random.uniform(0.05, 0.3)
    frequency = round(frequency, 2)
    
    phase_deg = random.randint(0, 359)

    if 0.2 <= frequency:
        height = random.uniform(0.02, 0.05)
    elif 0.12 <= frequency < 0.2:
        height = random.uniform(0.05, 0.1)    
    elif 0.10 <= frequency < 0.12:
        height = random.uniform(0.1, 0.2)
    else: # frequency < 0.1
        height = random.uniform(0.2, 0.5)

    height = round(height, 3) # In m
        
    return frequency, math.radians(phase_deg), height

def gen_wave_components():
    num_waves = random.randint(3, 10)
    
    wave_list = []
    for i in range(num_waves):
        frequency, phase_rad, height = gen_random_wave()
        W = wave(frequency, phase_rad, height)
        wave_list.append(W)
        
    return wave_list

def gen_wave_time(wave_list):
    period_arr  = [int(1/W.frequence) for W in wave_list]
    wave_duration = np.lcm.reduce(period_arr)    
    
    INI = random.choice(range(wave_duration))
    END = INI+MEASUREMENT_WINDOW
    time = np.arange(INI, END, MEASUREMENT_PERIOD)
    return time
    
def gen_sea_wave_data():    
    wave_list = gen_wave_components() # Sine waves composing the wave
  
    time = gen_wave_time(wave_list) # Time of datapoints
        
    # Generating Sine Waves
    sinewave_list = []
    for W in wave_list:
        sinewave_list.append(W.gen_sinewave(time))
        
    sea_wave_data = sum(sinewave_list)
    
    sea_level_offset = random.uniform(90, 110)
    sea_level_offset = 1

    sea_wave_data += sea_level_offset

    return sea_wave_data
       
def gen_dataframe_and_filename():

    data = gen_sea_wave_data()
    records = range(len(data))

    belize_now = datetime.now(pytz.timezone('America/Belize'))
    utcoffset = belize_now.utcoffset().total_seconds()/3600

    end_timestamp = datetime.now()+timedelta(hours=int(utcoffset))
    # end_timestamp -= timedelta(hours=pytz.timezone('America/Belize'))

    ini_timestamp = end_timestamp - timedelta(minutes=15)
    minute = math.floor(ini_timestamp.minute/15)*15
    ini_timestamp = ini_timestamp.replace(minute=minute, second=1, microsecond=0)
        
    timestamps = [ini_timestamp+timedelta(seconds=i) for i in range(len(data))]
    
    df = pd.DataFrame(list(zip(timestamps, records, data)), columns = ["TIMESTAMP","RECORD","SL"])   
    
    filename = datetime.strftime(ini_timestamp, "hf_data_%d_%b_%Y_%H_%M.dat")
    return df, filename

def get_df_data(df):
    buf_s = io.StringIO()
    df.to_csv(buf_s, sep=',', quoting=csv.QUOTE_NONNUMERIC, index=False, header=False)
    data = buf_s.getvalue()
    buf_s.close()
    return data

def add_header(data):
    line_1 = '"TOA5","23537","CR1000X","23537","CR1000X.Std.05.01","CPU:9958303_PGIA_11_03_2022.cr1x","57965","T_5min2"'
    line_2 = '"TIMESTAMP","RECORD","SL"'
    line_3 = '"TS","RN","mm","mbar","knots","Deg","W/m^2","Deg C","Deg C","%"'
    line_4 = '"","","Tot","Smp","Avg","WVc","Smp","Smp","Smp","Smp"'

    header = '\n'.join([line_1, line_2, line_3, line_4])
    return header+'\n'+data

def send_via_ftp(data, file_name):
    remote_folder = 'wave'
    remote_file_path = os.path.join('/', remote_folder, file_name)

    buf_b = io.BytesIO()
    buf_b.write(data.encode())
    buf_b.seek(0)

    try:
        ftp_server = FTPServer.objects.get(name='High Frequency Data Server')

        with FTP() as ftp:
            ftp.connect(host=ftp_server.host, port=ftp_server.port)
            ftp.login(user=ftp_server.username, passwd=ftp_server.password)
            ftp.set_pasv(val = not ftp_server.is_active_mode)

            if not remote_folder in ftp.nlst():
                ftp.mkd(remote_folder)

            ftp.storbinary(f"STOR {remote_file_path}", buf_b)
            ftp.quit()

        buf_b.close()
    except FTPServer.DoesNotExist:
        logger.warning('FTP Server named "High Frequency Data Server" not found skipping...')
        ftp_server = None

def format_and_send_data(df, file_name):
    data = get_df_data(df)
    data = add_header(data)

    send_via_ftp(data, file_name)
