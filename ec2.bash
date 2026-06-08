#!/bin/bash
yum update -y
yum install python3 python3-pip -y
pip3 install flask boto3

cat << 'EOF' > /home/ec2-user/app.py
from flask import Flask, render_template_string
import boto3
from boto3.dynamodb.conditions import Key
import time

app = Flask(__name__)
dynamodb = boto3.resource('dynamodb', region_name='us-east-1')
table = dynamodb.Table('ECG_Records')

HTML_TEMPLATE = """
<!DOCTYPE html>
<html>
<head>
    <title>Sistem Monitoring Vital Sign ECG</title>
    <meta http-equiv="refresh" content="5">
    <script src="https://cdn.jsdelivr.net/npm/chart.js"></script>
    <style>
        body { font-family: 'Segoe UI', Tahoma, Geneva, Verdana, sans-serif; margin: 0; padding: 0; background-color: #f0f2f5; color: #333; }
        .header-bar { background-color: #2c3e50; color: white; padding: 25px; text-align: center; box-shadow: 0 2px 4px rgba(0,0,0,0.1); }
        .container { max-width: 1050px; margin: 30px auto; background: white; padding: 30px; border-radius: 12px; box-shadow: 0 4px 15px rgba(0,0,0,0.05); }
        h1 { margin: 0; font-size: 24pt; font-weight: 600; }
        
        .status-badge { padding: 6px 14px; border-radius: 20px; font-weight: bold; color: white; display: inline-block; font-size: 10pt; text-transform: uppercase; }
        .Normal { background-color: #2ecc71; box-shadow: 0 2px 5px rgba(46,204,113,0.3); }
        .Tachycardia { background-color: #e74c3c; box-shadow: 0 2px 5px rgba(231,76,60,0.3); }
        .Bradycardia { background-color: #f1c40f; color: #2c3e50; }
        
        .Sensor.Terlepas { 
            background-color: #8e44ad; color: white; 
            box-shadow: 0 2px 8px rgba(142,68,173,0.5);
            animation: blinker 1s linear infinite; 
        }
        @keyframes blinker { 50% { opacity: 0.1; } }
        
        table { width: 100%; border-collapse: collapse; margin-top: 15px; background: white; border-radius: 8px; overflow: hidden; }
        th, td { padding: 15px; text-align: left; }
        th { background-color: #34495e; color: white; font-weight: 500; font-size: 11pt; }
        td { border-bottom: 1px solid #eef2f5; font-size: 11pt; }
        tr:hover { background-color: #f8f9fa; }
        strong.bpm-value { font-size: 13pt; color: #2c3e50; }
        strong.nama-pasien { color: #2980b9; font-size: 11.5pt; }
    </style>
</head>
<body>
    <div class="header-bar">
        <h1>🏥 Dashboard Monitoring ECG Pasien Real-Time</h1>
    </div>
    
    <div class="container">
        <div style="margin-bottom: 30px;">
            <h3 style="color: #2c3e50; margin-top: 0; border-bottom: 2px solid #eee; padding-bottom: 10px;">📈 Grafik Sinyal Gelombang Jantung Terkini</h3>
            <div style="background: #fafafa; border: 1px solid #ddd; border-radius: 8px; padding: 15px; margin-top: 15px;">
                <canvas id="ecgChart" height="70"></canvas> 
            </div>
        </div>

        <table>
            <thead>
                <tr>
                    <th>Nama Pasien</th>
                    <th>ID Perangkat</th>
                    <th>Waktu Pengambilan Data</th>
                    <th>Detak Jantung (BPM)</th>
                    <th>Status Medis Pasien</th>
                </tr>
            </thead>
            <tbody>
                {% for row in data %}
                <tr>
                    <td><strong class="nama-pasien">{{ row.nama_pasien }}</strong></td>
                    <td><span style="font-family: monospace; font-size: 11pt; color:#7f8c8d;">{{ row.device_id }}</span></td>
                    <td>{{ row.waktu_indo }}</td>
                    <td><strong class="bpm-value">{{ row.bpm }}</strong> <span style="font-size:9pt; color:gray;">BPM</span></td>
                    <td><span class="status-badge {{ row.status }}">{{ row.status }}</span></td>
                </tr>
                {% endfor %}
            </tbody>
        </table>
    </div>

    <script>
        const rawData = {{ latest_signal | tojson }};
        
        if (rawData && rawData.length > 0) {
            const ctx = document.getElementById('ecgChart').getContext('2d');
            const labels = Array.from({length: rawData.length}, (_, i) => i + 1);

            new Chart(ctx, {
                type: 'line',
                data: {
                    labels: labels,
                    datasets: [{
                        label: 'Sinyal Potensial Listrik (ADC)',
                        data: rawData,
                        borderColor: '#2980b9',
                        borderWidth: 1.5,
                        pointRadius: 0,
                        fill: false,
                        tension: 0.1
                    }]
                },
                options: {
                    animation: false,
                    scales: {
                        x: { display: false },
                        y: { suggestedMin: 1500, suggestedMax: 2500 } // Area kalibrasi grafis
                    },
                    plugins: { legend: { display: false } },
                    interaction: { intersect: false, mode: 'index' },
                }
            });
        } else {
            const ctx = document.getElementById('ecgChart').getContext('2d');
            ctx.font = "16px 'Segoe UI'";
            ctx.fillStyle = "#e74c3c";
            ctx.textAlign = "center";
            ctx.fillText("Menunggu transmisi data atau sensor terlepas...", document.getElementById('ecgChart').width/2, document.getElementById('ecgChart').height/2);
        }
    </script>
</body>
</html>
"""

@app.route('/')
def index():
    try:
        response = table.query(
            KeyConditionExpression=Key('device_id').eq('ESP32-ECG-PRO'),
            ScanIndexForward=False, 
            Limit=10
        )
        
        items = response.get('Items', [])
        
        latest_signal = []
        if items:
            raw_list = items[0].get('sinyal', [])
            latest_signal = [int(x) for x in raw_list]
        
        for item in items:
            waktu_lokal = time.localtime(int(item['timestamp']))
            item['waktu_indo'] = time.strftime('%Y-%m-%d %H:%M:%S', waktu_lokal)
            
        return render_template_string(HTML_TEMPLATE, data=items, latest_signal=latest_signal)
    except Exception as e:
        return f"<h3>Gagal memuat database DynamoDB: {str(e)}</h3>"

if __name__ == '__main__':
    app.run(host='0.0.0.0', port=80)
EOF

sudo nohup python3 /home/ec2-user/app.py > /home/ec2-user/app.log 2>&1 &