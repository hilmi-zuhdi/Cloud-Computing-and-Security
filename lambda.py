import json
import boto3
import os
import numpy as np
from datetime import datetime
from scipy.signal import find_peaks, butter, filtfilt, iirnotch
from decimal import Decimal

# WAJIB: Gunakan backend 'Agg' agar matplotlib bisa jalan di environment serverless tanpa GUI
import matplotlib
matplotlib.use('Agg')
import matplotlib.pyplot as plt

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
        
        start_time_epoch = event.get('start_time', 0)
        end_time_epoch = event.get('end_time', 0)
        
        now = datetime.now()
        timestamp = int(now.timestamp())
        
        bpm = 0.0
        status_medis = "Normal"
        alert_triggered = False
        condition_attr = "NORMAL"
        severity_attr = "INFO"
        presigned_url = None

        if is_lead_off:
            status_medis = "Sensor Terlepas"
            alert_triggered = True
            condition_attr = "LEAD_OFF"
            severity_attr = "CRITICAL"
        elif len(payload) > 0:
            data_array = np.array(payload)
            fs = 250  
            nyq = 0.5 * fs
            
            # Filter Sinyal (Notch & Bandpass)
            f0 = 50.0 
            Q = 30.0
            b_notch, a_notch = iirnotch(f0, Q, fs)
            notched_ecg = filtfilt(b_notch, a_notch, data_array)

            b_band, a_band = butter(1, [5.0/nyq, 15.0/nyq], btype='band')
            filtered_ecg = filtfilt(b_band, a_band, notched_ecg)
            
            # Komputasi Pan-Tompkins
            derivative = np.gradient(filtered_ecg)
            squared = derivative ** 2
            window_size = int(0.150 * fs) 
            mwi = np.convolve(squared, np.ones(window_size)/window_size, mode='same')
            
            adaptive_threshold = np.mean(mwi) * 1.5 
            peaks, _ = find_peaks(mwi, distance=int(fs * 0.25), height=adaptive_threshold)

            if len(peaks) >= 2:
                rr_intervals_indices = np.diff(peaks)
                rr_intervals_ms = rr_intervals_indices * (1000.0 / fs)
                avg_rr = np.mean(rr_intervals_ms)
                bpm = round((60000.0 / avg_rr), 2)
            
            # Triase Kondisi
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

            # --- SOLUSI ALTERNATIF 1: PLOT GRAFIK & GENERATE S3 URL ---
            if alert_triggered:
                # Membuat Grafik Visual
                plt.figure(figsize=(10, 4))
                waktu_x = np.linspace(0, 5, len(filtered_ecg)) # Rentang 5 Detik
                plt.plot(waktu_x, filtered_ecg, color='red' if condition_attr == "TACHYCARDIA" else 'blue')
                plt.title(f"Visualisasi ECG Jendela 5 Detik - {status_medis}")
                plt.xlabel("Waktu (Detik)")
                plt.ylabel("Amplitudo (ADC Filtered)")
                plt.grid(True)
                
                # Simpan gambar ke storage temporary Lambda
                temp_image_path = f"/tmp/ecg_{timestamp}.png"
                plt.savefig(temp_image_path)
                plt.close()
                
                # Upload gambar ke bucket S3
                s3_image_key = f"ecg-alerts-graph/{device_id}/{timestamp}.png"
                s3.upload_file(temp_image_path, BUCKET_NAME, s3_image_key, ExtraArgs={'ContentType': 'image/png'})
                
                # Generate Presigned URL (Valid 24 Jam) agar dokter bisa klik dan melihat gambar
                presigned_url = s3.generate_presigned_url(
                    'get_object',
                    Params={'Bucket': BUCKET_NAME, 'Key': s3_image_key},
                    ExpiresIn=86400 
                )

        # Simpan ke DynamoDB
        table.put_item(
            Item={
                'device_id': device_id,
                'nama_pasien': nama_pasien,
                'timestamp': timestamp,
                'start_time': int(start_time_epoch),
                'end_time': int(end_time_epoch),
                'bpm': Decimal(str(bpm)),
                'status': status_medis,
                'sinyal': payload 
            }
        )
        
        # Alert SNS dengan URL Lampiran Visual
        if alert_triggered and SNS_TOPIC_ARN:
            waktu_kejadian = now.strftime('%Y-%m-%d %H:%M:%S')
            message_body = f"DARURAT MEDIS!\n\nPasien: {nama_pasien} ({device_id})\nTerdeteksi: {status_medis}\nBPM: {bpm}\nWaktu Kejadian: {waktu_kejadian}\n"
            
            # Tambahkan link grafik jika ada
            if presigned_url:
                message_body += f"\n[DIAGNOSTIK KLINIS] Klik tautan berikut untuk melihat visualisasi grafik gelombang ECG 5 detik terakhir (Tautan kedaluwarsa dalam 24 jam):\n{presigned_url}"

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
            'body': json.dumps({'pesan': 'Pemrosesan berhasil', 'status': status_medis})
        }

    except Exception as e:
        print(f"Error fatal Lambda: {str(e)}")
        return {'statusCode': 500, 'body': json.dumps(f"Kesalahan internal: {str(e)}")}