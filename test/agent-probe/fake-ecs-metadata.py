"""ECS 태스크 메타데이터 엔드포인트(v4)를 흉내 낸다. 에이전트의 ECS 리소스 감지가 무엇을 만드는지 보려고 쓴다.
값은 형식만 맞춘 가짜다(계정 000000000000). 인자: 포트."""
import json
import sys
from http.server import BaseHTTPRequestHandler, HTTPServer

ARN = "arn:aws:ecs:ap-northeast-2:000000000000"
CONTAINER = {
    "DockerId": "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef",
    "Name": "app",
    "DockerName": "ecs-probe-1-app",
    "Image": "000000000000.dkr.ecr.ap-northeast-2.amazonaws.com/probe:abc123",
    "ImageID": "sha256:" + "0" * 64,
    "ContainerARN": ARN + ":container/probe-cluster/0123456789abcdef/aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee",
    "LogDriver": "awslogs",
    "LogOptions": {"awslogs-group": "/ecs/probe", "awslogs-region": "ap-northeast-2",
                   "awslogs-stream": "ecs/app/0123456789abcdef"},
}
TASK = {
    "Cluster": ARN + ":cluster/probe-cluster",
    "TaskARN": ARN + ":task/probe-cluster/0123456789abcdef",
    "Family": "probe",
    "Revision": "7",
    "AvailabilityZone": "ap-northeast-2a",
    "LaunchType": "FARGATE",
    "Containers": [CONTAINER],
}


class Handler(BaseHTTPRequestHandler):
    def do_GET(self):
        body = TASK if self.path.endswith("/task") else CONTAINER
        data = json.dumps(body).encode()
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def log_message(self, *args):
        pass


HTTPServer(("127.0.0.1", int(sys.argv[1])), Handler).serve_forever()
