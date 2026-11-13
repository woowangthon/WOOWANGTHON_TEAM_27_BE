"""Conservative domestic-subject gate, also applied to restored feed records."""
import re

KOREA = re.compile(r'대한민국|한국|서울|부산|인천|대구|광주|대전|울산|세종|경기|강원|충청|전라|경상|제주|코레일|KORAIL|서울교통공사|공항철도', re.I)
OVERSEAS = re.compile(r'스페인|에스파냐|마드리드|바르셀로나|프랑스|파리|영국|런던|독일|베를린|이탈리아|포르투갈|미국|뉴욕|일본|도쿄|중국|베이징|해외|외국|Spain|Spanish|Madrid|Barcelona|France|French|London|Germany|Italy|Portugal', re.I)


def domestic_subject(text):
    # No guessed domestic geography from a publisher, Korean language, or 전국.
    return bool(KOREA.search(text)) and not OVERSEAS.search(text)


def domestic_impact(impact):
    return domestic_subject(' '.join([impact.get('event_name', '')] +
                                   [e.get('quote', '') for e in impact.get('evidence', [])]))
