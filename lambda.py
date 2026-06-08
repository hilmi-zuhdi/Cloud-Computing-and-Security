import json
import boto3
import os
import numpy as np
from datetime import datetime
from scipy.signal import find_peaks, butter, filtfilt, iirnotch
from decimal import Decimal

# Environment Variables
TABLE_NAME = os.environ.get('TABLE_NAME', 'ECG_Records')
BUCKET_NAME = os.environ.get('BUCKET_NAME', 'ecg-raw-archives')
SNS_TOPIC_ARN = os.environ.get('SNS_TOPIC_ARN')

# Inisialisasi Boto3
dynamodb = boto3.resource('dynamodb')
table = dynamodb.Table(TABLE_NAME)
s3 = boto3.client('s3')
sns = boto3.client('sns')

def lambda_handler(event, context):
    try:
        device_id = event.get('device_id', 'Unknown-Device')
        nama_pasien = event.get('nama_pasien', 'Pasien Anonim')
        is_lead_off = event.get('lead_off', False)
        payload = event.get('payload', [])
        
        now = datetime.now()
        timestamp = int(now.timestamp())
        
        bpm = 0.0
        status_medis = "Normal"
        alert_triggered = False
        condition_attr = "NORMAL"
        severity_attr = "INFO"

        grafik_data = {
            "raw": payload,
            "filtered": [],
            "integration": [],
            "threshold": []
        }

        if is_lead_off:
            status_medis = "Sensor Terlepas"
            alert_triggered = True
            condition_attr = "LEAD_OFF"
            severity_attr = "CRITICAL"
        elif len(payload) > 0:
            data_array = np.array(payload)
            fs = 250  
            nyq = 0.5 * fs
            
            # Notch Filter 50 Hz (Membuang interferensi kelistrikan)
            f0 = 50.0 
            Q = 30.0
            b_notch, a_notch = iirnotch(f0, Q, fs)
            notched_ecg = filtfilt(b_notch, a_notch, data_array)

            # Bandpass Filter 5 - 15 Hz
            b_band, a_band = butter(1, [5.0/nyq, 15.0/nyq], btype='band')
            filtered_ecg = filtfilt(b_band, a_band, notched_ecg)
            
            # Derivative & Squaring
            derivative = np.gradient(filtered_ecg)
            squared = derivative ** 2
            
            # Moving Window Integration (MWI)
            window_size = int(0.150 * fs) 
            mwi = np.convolve(squared, np.ones(window_size)/window_size, mode='same')
            
            # Adaptive Thresholding & Find Peaks
            adaptive_threshold = np.mean(mwi) * 1.5 
            peaks, _ = find_peaks(mwi, distance=int(fs * 0.25), height=adaptive_threshold)
            
            grafik_data["filtered"] = np.round(filtered_ecg, 2).tolist()
            grafik_data["integration"] = np.round(mwi, 2).tolist()
            grafik_data["threshold"] = [round(adaptive_threshold, 2)] * len(payload)

            if len(peaks) >= 2:
                rr_intervals_indices = np.diff(peaks)
                rr_intervals_ms = rr_intervals_indices * (1000.0 / fs)
                avg_rr = np.mean(rr_intervals_ms)
                bpm = round((60000.0 / avg_rr), 2)
            
            # ========================================================
            # INTERVENSI DEMO MODE (Ubah via Environment Variable AWS)
            # ========================================================
            demo_mode = os.environ.get('DEMO_MODE', 'DISABLED')
            
            if demo_mode == 'TACHYCARDIA':
                bpm = bpm * 1.8 
                if bpm < 110: 
                    bpm = 135.0 
            elif demo_mode == 'BRADYCARDIA':
                bpm = bpm * 0.5
                if bpm > 50: 
                    bpm = 45.0
                    
            # Pastikan nilai kembali rapi dengan 2 angka di belakang koma
            bpm = round(bpm, 2)
            # ========================================================

            # Triase
            if bpm > 100:
                status_medis = "Tachycardia"
                alert_triggered = True
                condition_attr = "TACHYCARDIA"
                severity_attr = "WARNING"
            elif 0 < bpm < 60:
                status_medis = "Bradycardia"
                alert_triggered = True
                condition_attr = "BRADYCARDIA"
                severity_attr = "WARNING"

        # Simpan DynamoDB
        table.put_item(
            Item={
                'device_id': device_id,
                'nama_pasien': nama_pasien,
                'timestamp': timestamp,
                'bpm': Decimal(str(bpm)),
                'status': status_medis,
                'sinyal': payload 
            }
        )
        
        # Backup S3
        year, month, day = now.strftime("%Y"), now.strftime("%m"), now.strftime("%d")
        s3_key = f"ecg-raw/{device_id}/{year}/{month}/{day}/{timestamp}.json"
        s3.put_object(Bucket=BUCKET_NAME, Key=s3_key, Body=json.dumps(event))

        # Alert SNS
        if alert_triggered and SNS_TOPIC_ARN:
            waktu_kejadian = now.strftime('%Y-%m-%d %H:%M:%S')
            message_body = f"Darurat Medis! Pasien {nama_pasien} ({device_id}) terdeteksi: {status_medis} pada {waktu_kejadian}."
            sns.publish(
                TopicArn=SNS_TOPIC_ARN,
                Subject=f"ALERT: {status_medis} - {nama_pasien}",
                Message=message_body,
                MessageAttributes={
                    'severity': {'DataType': 'String', 'StringValue': severity_attr},
                    'condition': {'DataType': 'String', 'StringValue': condition_attr}
                }
            )

        return {
            'statusCode': 200,
            'headers': {
                'Content-Type': 'application/json',
                'Access-Control-Allow-Origin': '*'
            },
            'body': json.dumps({
                'pesan': 'Pemrosesan berhasil',
                'bpm': bpm,
                'status': status_medis,
                'grafik': grafik_data
            })
        }

    except Exception as e:
        print(f"Error fatal Lambda: {str(e)}")
        return {'statusCode': 500, 'body': json.dumps(f"Kesalahan internal: {str(e)}")}