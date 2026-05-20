# n8n Queue Mode Installer

Bộ script này cài n8n theo queue mode:

- VPS main chạy n8n UI/webhook, Caddy SSL, Postgres, Redis và 1 worker local.
- VPS worker chỉ chạy n8n worker, không cần domain, không cần SSL, không expose port public.
- Worker kết nối về main bằng host/password của Postgres, Redis và `N8N_ENCRYPTION_KEY`.

## Files

- `install_n8n_queue_main.sh`: cài cụm main queue mode.
- `install_n8n_queue_worker.sh`: cài worker remote trên VPS bất kỳ.
- `README.md`: hướng dẫn sử dụng.

## Kiến trúc

```text
Webhook / UI
    |
    v
Caddy SSL -> n8n-main
               |
               v
          Redis queue
               |
      +--------+--------+
      |                 |
worker local      worker remote VPS 1/2/3...
      |
      v
Postgres chung
```

Tất cả main và worker dùng chung:

- Postgres database
- Redis queue
- `N8N_ENCRYPTION_KEY`
- n8n image tag/version

## Cài VPS Main

Yêu cầu:

- VPS Ubuntu/Debian.
- Domain/subdomain đã trỏ về IP VPS main.
- Chạy bằng user `root`.

Chạy:

```bash
bash install_n8n_queue_main.sh
```

Script sẽ hỏi:

- domain n8n, ví dụ `n8n.example.com`;
- host/IP public để worker kết nối về main;
- port Postgres, mặc định `5432`;
- port Redis, mặc định `6379`;
- concurrency của worker local, mặc định `5`;
- n8n image tag, mặc định `latest`;
- có bật auto update hay không.

Sau khi cài xong, truy cập:

```text
https://domain-cua-ban
```

Các file quan trọng trên main:

```bash
/home/n8n/.env
/home/n8n/worker-connection.env
/home/n8n/show-worker-config.sh
/home/n8n/backup-n8n.sh
/home/n8n/restart-n8n.sh
/home/n8n/update-n8n.sh
```

Xem thông tin để cài worker:

```bash
/home/n8n/show-worker-config.sh
```

## Cài VPS Worker

SSH vào VPS worker bằng root rồi chạy:

```bash
bash install_n8n_queue_worker.sh
```

Script sẽ hỏi các giá trị lấy từ main:

```text
MAIN_HOST
POSTGRES_HOST
POSTGRES_PORT
POSTGRES_DB
POSTGRES_USER
POSTGRES_PASSWORD
REDIS_HOST
REDIS_PORT
REDIS_PASSWORD
N8N_ENCRYPTION_KEY
N8N_VERSION
```

Worker không cần domain, không cần SSL, không publish port.

Các lệnh hữu ích trên worker:

```bash
/home/n8n-worker/check-connection.sh
/home/n8n-worker/logs-worker.sh
/home/n8n-worker/restart-worker.sh
/home/n8n-worker/update-worker.sh
```

Thêm worker mới:

1. SSH vào VPS mới.
2. Chạy `bash install_n8n_queue_worker.sh`.
3. Nhập lại thông tin từ `/home/n8n/show-worker-config.sh`.

Không cần restart main.

## Kiểm Tra Hoạt Động

Trên main:

```bash
cd /home/n8n
docker compose ps
docker compose logs -f
```

Trên worker:

```bash
cd /home/n8n-worker
docker compose ps
docker compose logs -f n8n-worker
```

Tạo một workflow test trong n8n rồi chạy nhiều execution. Worker remote sẽ lấy job từ Redis và ghi kết quả về Postgres.

## Backup

Trên main:

```bash
/home/n8n/backup-n8n.sh
```

Backup sẽ nằm trong:

```bash
/home/n8n/backups/
```

Backup gồm:

- Postgres dump;
- `.env`;
- `worker-connection.env`;
- `docker-compose.yml`;
- `Dockerfile`;
- `Caddyfile`.

## Update

Khuyến nghị không bật auto update nếu đang chạy nhiều worker, vì main và worker nên dùng cùng version n8n.

Update thủ công theo thứ tự:

1. Backup main:

```bash
/home/n8n/backup-n8n.sh
```

2. Update main:

```bash
/home/n8n/update-n8n.sh
```

3. Update từng worker:

```bash
/home/n8n-worker/update-worker.sh
```

Nếu muốn dùng version cố định thay vì `latest`, nhập tag cụ thể khi cài, ví dụ:

```text
1.100.1
```

Sau đó main và tất cả worker nên dùng cùng tag.

## Bảo Mật

Host/password mode dễ thêm worker mới, nhưng rủi ro cao hơn VPN/private network.

Main sẽ mở:

- Postgres: mặc định `5432`;
- Redis: mặc định `6379`.

Ai có được các thông tin sau gần như có quyền đọc/sửa toàn bộ cụm n8n:

- `POSTGRES_PASSWORD`
- `REDIS_PASSWORD`
- `N8N_ENCRYPTION_KEY`

Nếu có thể, nên giới hạn firewall chỉ cho IP worker truy cập `5432` và `6379`. Nếu không giới hạn firewall, hãy coi mọi worker là máy tin cậy cao.

Khi nghi ngờ worker bị lộ:

1. Dừng worker đó ngay.
2. Đổi password Postgres.
3. Đổi password Redis.
4. Rotate credentials bên trong n8n.
5. Kiểm tra workflow và execution logs.
6. Dựng lại worker từ VPS sạch.

## Lưu Ý Về Worker

Worker không có UI và không cần port public. Script hiện tại không dùng port `113123`.

Nếu sau này bật health check port cho worker, hãy chọn port hợp lệ trong khoảng `1-65535`. `113123` không phải TCP port hợp lệ.

Binary data được cấu hình là `database` để nhiều worker ở nhiều VPS có thể đọc cùng dữ liệu.

Nếu workflow dùng file local trong `/files` hoặc `/home/my-files`, file đó phải tồn tại trên worker thực thi job. Với nhiều VPS worker, nên tránh phụ thuộc file local hoặc dùng object storage/shared storage.

Nếu dùng community nodes/custom nodes, hãy đảm bảo main và tất cả worker có cùng package node. Cách ổn định nhất là build các package đó vào Dockerfile custom dùng chung cho main và worker.
