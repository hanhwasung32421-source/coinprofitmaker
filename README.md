# Calcu 스크린샷 생성기 (Python 로컬 프로그램)

첨부된 스크린샷과 동일한 형태로 **배경(`calcu/bg.png`) 위에 숫자/텍스트를 올려서 PNG로 저장**하는 로컬 프로그램입니다.

## 1) 설치

터미널에서 이 폴더로 이동 후:

```bash
pip install -r c:\trae\requirements.txt
```

## 2) 실행

```bash
python c:\trae\calcu_generator.py
```

## 3) Roboto 폰트(완전 동일하게 맞추기)

프로그램은 Roboto를 우선 사용합니다. PC에 Roboto가 없으면 기본 폰트로 대체되어 **완전 동일하게** 나오지 않을 수 있어요.  
완벽히 동일하게 맞추려면 아래 파일을 이 폴더에 넣어주세요:

```
c:\trae\calcu\fonts\Roboto-Regular.ttf
c:\trae\calcu\fonts\Roboto-Medium.ttf
c:\trae\calcu\fonts\Roboto-Bold.ttf
```

넣은 뒤 프로그램을 다시 실행하면 자동으로 적용됩니다.

## 4) 랜덤/자동 계산/대량 생성

- **수익률 범위**(예: `20~25`)를 입력하면 그 범위 안에서 **소수점 2자리**로 랜덤 생성됩니다.
- **수익금 범위**(예: `3,000,000~10,000,000`)를 입력하면 그 범위 안에서 **정수(1의 자리까지)**로 랜덤 생성됩니다.
- **Entry Price**는 사용자가 입력하고, **Exit Price는 수익률을 기반으로 자동 계산**되어 표시됩니다.
  - LONG: `exit = entry * (1 + 수익률/100)`
  - SHORT: `exit = entry * (1 - 수익률/100)`
  - Exit은 **소수점 5자리 반올림**으로 표시됩니다.
- **생성 개수**에 숫자를 넣고 **대량 생성**을 누르면, 입력한 개수만큼 PNG가 연속 저장됩니다.
