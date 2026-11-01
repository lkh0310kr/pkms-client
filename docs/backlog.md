로컬에 저장하지 않고 웹에서 바로 수정가능한
github based pkms-client
기존에는 클라이언트들이 로컬에 정보를 다 저장하고 수동으로 github에 커밋 푸시하여 동기화하는 방식.
github를 DB 클라우드로 사용하고 웹에서 내 github 계정으로 로그인하면 바로 수정가능한거임. 노션처럼 최고의 자동저장 실시간 UX를 보여줘야함. react-router start같은 풀스택 프레임워크를 사용해서 vercel에 배포하면될거같고 백엔드에서 변경사항을 모아서 깃헙에 동기화하면 될듯.

1. 최고의 UX를 선사해야함.
    - Notion 수준으로 끊김이 없어야함.
    - 파일 업로드나 뷰어도 끊김이 없어야함.
2. 타 client들과 동기화가 잘 되어야 함.

- Web Client
    - [x] TreeView 파일 list fetching 중일때 로딩 상태.
    - [x] Markdown Editor
        - [x] 표 렌더링
        - [x] Title underline 없애고 '#', '##', '###' 크기를 Title Size와 동일하게 맞춤
        - [x] divider ('---') 렌더링
        - [x] link와 URL을 underline 없이 primary color로 표시
        - [x] favicon 설정
        - [x] checkbox 렌더링 및 클릭으로 완료 상태 변경 (- [ ], - [x])
        - [x] 파일을 여는 동안 로딩 표시를 띄우고 이전 내용을 숨김
    - [x] TreeView 우클릭 시 브라우저 기본 메뉴가 같이 뜨는 문제
    - [x] Show hidden files 버튼을 없애고 Cmd + Shift + . 로 ignored 파일 표시
    - [x] 사이드바 버튼 및 Cmd + \ 토글 추가, Workspace 추가 버튼 이동

## 기술 검토

- 기능들은 기술적으로 구현 가능하다. 다만 GitHub는 실시간 편집 DB가 아니라 백업 대상이다. 현재 구현은 Supabase에 편집 내용과 협업 상태를 저장하고 Worker가 GitHub로 주기적으로 커밋한다. 따라서 Supabase는 단순 캐시가 아니며, GitHub 백업 전 장애 시 복구 시점 정책이 필요하다.
- GitHub 인증 사용자의 REST API 한도는 일반적으로 시간당 5,000회다. Contents API는 디렉터리당 1,000개 항목 제한이 있고, recursive Git Trees는 결과가 100,000개 또는 7 MB를 넘으면 잘릴 수 있다. 현재처럼 폴더를 필요할 때만 읽고 커밋을 묶는 방식은 적절하지만, 큰 저장소에는 잘림 감지, 재시도, backoff가 필요하다.
- 빠른 편집 UX를 위해 브라우저 IndexedDB 캐시는 유용하다. 이는 사용자가 저장소를 직접 clone해야 한다는 뜻은 아니다. 브라우저 저장 공간을 전혀 쓰지 않으면 새로고침/오프라인 복원과 체감 속도가 나빠지므로, 로컬 clone과 브라우저 캐시를 구분해야 한다.
- 현재 실시간 채널은 Supabase Realtime을 사용하고 Worker의 `/stream` 경로는 503을 반환한다. 따라서 “백엔드 Worker 자체가 WebSocket을 중계한다”는 목표와 다르다. 외부 서비스 수를 줄이려면 인증, workspace별 fan-out, reconnect, presence와 Yjs 업데이트 전달을 포함한 Worker WebSocket 전환을 별도 설계/검증해야 한다.

참고: [GitHub REST API rate limits](https://docs.github.com/en/rest/using-the-rest-api/rate-limits-for-the-rest-api), [Contents API limits](https://docs.github.com/en/rest/repos/contents), [Git Trees limits](https://docs.github.com/en/rest/git/trees).
